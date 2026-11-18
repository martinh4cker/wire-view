package dev.wireview.receiver;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.SurfaceTexture;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaFormat;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.ParcelFileDescriptor;
import android.system.Os;
import android.system.OsConstants;
import android.system.ErrnoException;
import android.util.Log;
import android.view.Gravity;
import android.view.Surface;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.TextView;
import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.io.FileDescriptor;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.concurrent.atomic.AtomicBoolean;

public final class MainActivity extends Activity implements VideoSurfaceView.Listener {
    private static final String TAG = "WireView";
    private static final int PORT = 27183;
    private static final int MAGIC = 0x57545332; // WTS2
    private static final int MAX_FRAME = 4 * 1024 * 1024;
    private static final int TCP_QUICKACK = 12; // Linux UAPI, per-socket; not an Android global setting.
    private FrameLayout root;
    private VideoSurfaceView view;
    private SurfaceTexture decoderTexture;
    private boolean resumed;
    private volatile CadenceStats composed;
    private TextView status;
    private Receiver receiver;
    private int videoWidth, videoHeight;

    // Measure each stage independently; decoder callbacks alone do not prove display cadence.
    private static final class CadenceStats {
        private final String stage;
        private final double[] gapsMs = new double[120];
        private final double[] sourceGapsMs = new double[120];
        private long start, previous, previousPTS;
        private int count;

        CadenceStats(String stage) { this.stage = stage; }

        void record(long pts, long now) {
            if (previous != 0) {
                gapsMs[count] = (now - previous) / 1e6;
                sourceGapsMs[count] = (pts - previousPTS) / 1e3;
                count++;
            } else start = now;
            previous = now;
            previousPTS = pts;
            if (count != gapsMs.length) return;
            double fps = count * 1e9 / (now - start);
            int bursts = 0, stalls = 0;
            for (double gap : gapsMs) {
                if (gap < 2) bursts++;
                if (gap > 25) stalls++;
            }
            Arrays.sort(gapsMs);
            Arrays.sort(sourceGapsMs);
            Log.i(TAG, String.format(Locale.ROOT,
                "Cadence %s: %.1f fps, gap p50/p95 %.2f/%.2f ms, source p50/p95 %.2f/%.2f ms, bursts<2ms=%d stalls>25ms=%d",
                stage, fps, gapsMs[59], gapsMs[113], sourceGapsMs[59], sourceGapsMs[113], bursts, stalls));
            start = now;
            count = 0;
        }
    }

    private static final class FrameTiming {
        final long received = System.nanoTime();
        long output;
    }

    private static final class FrameTimings {
        private final LinkedHashMap<Long, FrameTiming> pending = new LinkedHashMap<>();
        private final CadenceStats received = new CadenceStats("received");
        private final CadenceStats output = new CadenceStats("decoded");

        synchronized void received(long pts) {
            received.record(pts, System.nanoTime());
            if (pending.size() >= 256) pending.remove(pending.keySet().iterator().next());
            pending.put(pts, new FrameTiming());
        }

        synchronized void output(long pts) {
            output.record(pts, System.nanoTime());
            FrameTiming timing = pending.get(pts);
            if (timing != null) timing.output = System.nanoTime();
        }

        synchronized FrameTiming rendered(long pts) { return pending.remove(pts); }
    }

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        view = new VideoSurfaceView(this, this);
        root.addView(view, new FrameLayout.LayoutParams(-1, -1, Gravity.CENTER));
        status = new TextView(this);
        status.setTextColor(Color.WHITE);
        status.setTextSize(22);
        status.setGravity(Gravity.CENTER);
        status.setText(WireViewStrings.waitingForMac());
        root.addView(status, new FrameLayout.LayoutParams(-1, -1));
        root.addOnLayoutChangeListener((v, l, t, r, b, ol, ot, or, ob) -> fitVideo());
        setContentView(root);
    }

    @Override public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (!hasFocus) return;
        if (Build.VERSION.SDK_INT >= 30) {
            WindowInsetsController insets = getWindow().getInsetsController();
            if (insets != null) {
                insets.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
                insets.hide(WindowInsets.Type.systemBars());
            }
        } else {
            getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN
                | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
        }
    }

    private void fitVideo() {
        if (videoWidth == 0 || root.getWidth() == 0 || root.getHeight() == 0) return;
        double scale = Math.min((double) root.getWidth() / videoWidth,
                                (double) root.getHeight() / videoHeight);
        int width = (int) (scale * videoWidth), height = (int) (scale * videoHeight);
        if (view.getLayoutParams().width != width || view.getLayoutParams().height != height) {
            view.setLayoutParams(new FrameLayout.LayoutParams(width, height, Gravity.CENTER));
        }
    }

    @Override public void onResume() {
        super.onResume();
        resumed = true;
        view.onResume();
        startReceiver();
    }

    @Override public void onPause() {
        resumed = false;
        stopReceiver();
        view.onPause();
        view.releaseDecoderTexture();
        decoderTexture = null;
        super.onPause();
    }

    private void startReceiver() {
        if (!resumed || receiver != null || decoderTexture == null) return;
        composed = new CadenceStats("GPU-latched");
        receiver = new Receiver(new Surface(decoderTexture));
        new Thread(receiver, "usb-video-receiver").start();
    }

    private void stopReceiver() {
        if (receiver != null) receiver.stop();
        receiver = null;
        composed = null;
    }

    @Override public void onDecoderTextureAvailable(SurfaceTexture texture) {
        if (decoderTexture != texture) stopReceiver();
        decoderTexture = texture;
        startReceiver();
    }

    @Override public void onDecoderTextureDestroyed(SurfaceTexture texture) {
        if (decoderTexture != texture) return;
        stopReceiver();
        decoderTexture = null;
    }

    @Override public void onVideoFrameLatched(long timestampNS, long nowNS) {
        CadenceStats stats = composed;
        if (stats != null) stats.record(timestampNS / 1000, nowNS);
    }

    @Override public void onVideoRenderError() {
        stopReceiver();
        status.setText(WireViewStrings.renderFailed());
        status.setVisibility(View.VISIBLE);
    }

    private final class Receiver implements Runnable {
        final Surface surface;
        volatile boolean stopped;
        volatile Socket socket;
        Receiver(Surface surface) { this.surface = surface; }

        void stop() {
            stopped = true;
            Socket current = socket;
            if (current != null) try { current.close(); } catch (IOException ignored) {}
        }

        void report(String message) {
            runOnUiThread(() -> {
                if (receiver != this) return;
                status.setText(message);
                status.setVisibility(message.isEmpty() ? TextView.GONE : TextView.VISIBLE);
            });
        }

        @Override public void run() {
            try { receiveUntilStopped(); }
            finally { surface.release(); }
        }

        private void receiveUntilStopped() {
            while (!stopped) {
                try (Socket connection = new Socket()) {
                    socket = connection;
                    if (stopped) return;
                    connection.connect(new InetSocketAddress("127.0.0.1", PORT), 1000);
                    connection.setSoTimeout(8000);
                    connection.setTcpNoDelay(true);
                    play(new DataInputStream(new BufferedInputStream(connection.getInputStream())),
                        new DataOutputStream(connection.getOutputStream()), connection);
                } catch (Exception e) {
                    if (!stopped) {
                        if (!(e instanceof java.net.ConnectException)) Log.i(TAG, "Stream ended", e);
                        report(WireViewStrings.waitingForMac());
                    }
                } finally {
                    socket = null;
                }
                if (!stopped) try { Thread.sleep(500); } catch (InterruptedException e) { return; }
            }
        }

        private void play(DataInputStream input, DataOutputStream acknowledgements, Socket connection)
                throws IOException, InterruptedException {
            try (ParcelFileDescriptor fd = ParcelFileDescriptor.fromSocket(connection)) {
                playWithQuickAck(input, acknowledgements, connection, fd.getFileDescriptor());
            }
        }

        private void playWithQuickAck(DataInputStream input, DataOutputStream acknowledgements, Socket connection, FileDescriptor fd)
                throws IOException, InterruptedException {
            boolean quickAck = true;
            try { Os.setsockoptInt(fd, OsConstants.IPPROTO_TCP, TCP_QUICKACK, 1); }
            catch (ErrnoException e) { quickAck = false; Log.i(TAG, "TCP quick ACK unavailable"); }
            if (input.readInt() != MAGIC) throw new IOException("Invalid stream header");
            int width = input.readInt(), height = input.readInt(), rate = input.readInt();
            if (width < 16 || width > 4096 || height < 16 || height > 4096 || rate < 1 || rate > 120)
                throw new IOException("Invalid video mode");
            runOnUiThread(() -> {
                if (receiver != this) return;
                videoWidth = width;
                videoHeight = height;
                fitVideo();
            });
            MediaFormat format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height);
            // The stream header is authoritative; otherwise this codec defaults its output to 30 fps.
            format.setInteger(MediaFormat.KEY_FRAME_RATE, rate);
            format.setInteger(MediaFormat.KEY_PRIORITY, 0);
            format.setFloat(MediaFormat.KEY_OPERATING_RATE, rate);
            String decoder = new MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(format);
            if (decoder == null) throw new IOException("No AVC decoder");
            MediaCodec codec = MediaCodec.createByCodecName(decoder);
            AtomicBoolean playing = new AtomicBoolean(true);
            FrameTimings timings = new FrameTimings();
            HandlerThread renderEvents = new HandlerThread("render-events");
            Thread output = null;
            try {
                MediaCodecInfo info = codec.getCodecInfo();
                MediaCodecInfo.CodecCapabilities capabilities = info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC);
                boolean lowLatency = Build.VERSION.SDK_INT >= 30
                    && capabilities.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency);
                if (lowLatency) format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
                codec.configure(format, surface, null, 0);
                final int[] rendered = {0};
                final long[] lastReport = {0};
                final double[] decodeMs = new double[120];
                final int[] measuredFrames = {0};
                final CadenceStats callbacks = new CadenceStats("render-callback");
                renderEvents.start();
                codec.setOnFrameRenderedListener((c, pts, time) -> {
                    if (stopped || !playing.get()) return;
                    callbacks.record(pts, time);
                    int count = ++rendered[0];
                    if (count == 1) {
                        lastReport[0] = time;
                        report("");
                        Log.i(TAG, "Rendered first frame");
                    } else if ((count - 1) % 120 == 0) {
                        double measured = 120e9 / (time - lastReport[0]);
                        lastReport[0] = time;
                        Log.i(TAG, String.format(Locale.ROOT, "Codec callbacks %d frames, %.1f fps", count, measured));
                    }
                    if (count % 10 == 0) {
                        try { acknowledgements.writeLong(pts); }
                        catch (IOException e) { close(connection); }
                    }
                    FrameTiming timing = timings.rendered(pts);
                    if (timing != null && timing.output >= timing.received) {
                        int i = measuredFrames[0]++;
                        decodeMs[i] = (timing.output - timing.received) / 1e6;
                        if (measuredFrames[0] == decodeMs.length) {
                            Arrays.sort(decodeMs);
                            Log.i(TAG, String.format(Locale.ROOT,
                                "Tablet timing p50 over %d frames: receive-to-decoder-output %.1f ms",
                                decodeMs.length, decodeMs[59]));
                            measuredFrames[0] = 0;
                        }
                    }
                }, new Handler(renderEvents.getLooper()));
                codec.start();
                // Codec setup can reset producer hints; apply the Surface vote after it starts.
                runOnUiThread(() -> {
                    if (receiver != this || !playing.get() || !surface.isValid()) return;
                    if (Build.VERSION.SDK_INT >= 30) {
                        view.setTargetFrameRate(rate);
                    }
                    view.postDelayed(() -> {
                        if (receiver == this && playing.get() && view.getDisplay() != null) {
                            Log.i(TAG, "Display refresh=" + view.getDisplay().getRefreshRate() + ", requested=" + rate);
                        }
                    }, 1000);
                });
                output = new Thread(() -> drain(codec, playing, connection, timings), "decoder-output");
                output.start();
                Log.i(TAG, "Decoder: " + decoder + ", " + width + "x" + height + " @ " + rate
                    + ", reportedModeSupport=" + capabilities.getVideoCapabilities().areSizeAndRateSupported(width, height, rate)
                    + ", lowLatency=" + lowLatency + ", hardware="
                    + (Build.VERSION.SDK_INT >= 29 && info.isHardwareAccelerated()));
                byte[] frame = new byte[256 * 1024];
                while (!stopped && playing.get()) {
                    int size = input.readInt();
                    if (size == 0) continue; // keepalive
                    long pts = input.readLong();
                    int flags = input.readInt();
                    if (size < 0 || size > MAX_FRAME || (flags & ~3) != 0)
                        throw new IOException("Invalid frame header");
                    if (frame.length < size) frame = new byte[size];
                    input.readFully(frame, 0, size);
                    if (quickAck) {
                        try { Os.setsockoptInt(fd, OsConstants.IPPROTO_TCP, TCP_QUICKACK, 1); }
                        catch (ErrnoException e) { quickAck = false; }
                    }
                    if ((flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) timings.received(pts);
                    int index = -1;
                    while (!stopped && playing.get() && (index = codec.dequeueInputBuffer(5000)) < 0) { }
                    if (stopped || !playing.get() || index < 0) return;
                    queueFrame(codec, frame, size, pts, flags, index);
                }
            } finally {
                playing.set(false);
                if (output != null) output.join();
                renderEvents.quitSafely();
                codec.release();
            }
        }

        private void queueFrame(MediaCodec codec, byte[] frame, int size, long pts, int flags, int index) throws IOException {
            ByteBuffer target = codec.getInputBuffer(index);
            if (target == null || target.remaining() < size) throw new IOException("Frame exceeds decoder buffer");
            target.put(frame, 0, size);
            codec.queueInputBuffer(index, 0, size, pts, flags);
        }

        private void drain(MediaCodec codec, AtomicBoolean playing, Socket connection, FrameTimings timings) {
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            try {
                while (!stopped && playing.get()) {
                    int index = codec.dequeueOutputBuffer(info, 5000);
                    if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        MediaFormat format = codec.getOutputFormat();
                        Log.i(TAG, "Decoder output frame-rate="
                            + (Build.VERSION.SDK_INT >= 29 && format.containsKey(MediaFormat.KEY_FRAME_RATE)
                                ? format.getNumber(MediaFormat.KEY_FRAME_RATE) : "unspecified"));
                    }
                    if (index < 0) continue;
                    if (info.size > 0 && (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                        timings.output(info.presentationTimeUs);
                        // The PTS belongs to the Mac clock; use the tablet clock to render immediately.
                        codec.releaseOutputBuffer(index, System.nanoTime());
                    } else {
                        codec.releaseOutputBuffer(index, false);
                    }
                }
            } catch (RuntimeException e) {
                if (playing.get() && !stopped) Log.w(TAG, "Decoder output ended", e);
                playing.set(false);
                close(connection);
            }
        }

        private void close(Socket connection) {
            try { connection.close(); } catch (IOException ignored) { }
        }
    }
}
