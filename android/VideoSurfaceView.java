package dev.wireview.receiver;

import android.content.Context;
import android.graphics.SurfaceTexture;
import android.opengl.GLES11Ext;
import android.opengl.GLES20;
import android.opengl.GLSurfaceView;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Surface;
import android.view.SurfaceHolder;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.util.concurrent.atomic.AtomicBoolean;
import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.opengles.GL10;

/** Decode into an external texture, then present RGB buffers on the display's EGL cadence. */
final class VideoSurfaceView extends GLSurfaceView implements GLSurfaceView.Renderer {
    interface Listener {
        // Surface lifecycle callbacks run on the main thread; frame metrics run on the GL thread.
        void onDecoderTextureAvailable(SurfaceTexture texture);
        void onDecoderTextureDestroyed(SurfaceTexture texture);
        void onVideoFrameLatched(long timestampNS, long nowNS);
        void onVideoRenderError();
    }

    private final Listener listener;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final AtomicBoolean pending = new AtomicBoolean();
    private final AtomicBoolean idlePosted = new AtomicBoolean();
    private final FloatBuffer vertices = ByteBuffer.allocateDirect(16 * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer();
    private final float[] matrix = new float[16];
    private volatile SurfaceTexture input;
    private volatile long lastFrameNS;
    private int textureID, program, position, coords, transform;
    private int width, height;
    private long lastTimestamp;
    private boolean hasFrame, failed;

    VideoSurfaceView(Context context, Listener listener) {
        super(context);
        this.listener = listener;
        vertices.put(new float[] {-1,-1,0,0, 1,-1,1,0, -1,1,0,1, 1,1,1,1}).position(0);
        setEGLContextClientVersion(2);
        setEGLConfigChooser(8, 8, 8, 0, 0, 0);
        setRenderer(this);
        setRenderMode(RENDERMODE_WHEN_DIRTY);
    }

    void setTargetFrameRate(int rate) {
        if (Build.VERSION.SDK_INT >= 30 && getHolder().getSurface().isValid()) {
            getHolder().getSurface().setFrameRate(rate, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE);
        }
    }

    // Call only after onPause() or super.surfaceDestroyed() has stopped GL drawing.
    void releaseDecoderTexture() {
        SurfaceTexture previous = input;
        input = null;
        pending.set(false);
        if (previous != null) {
            listener.onDecoderTextureDestroyed(previous);
            previous.setOnFrameAvailableListener(null);
            previous.release();
        }
    }

    @Override public void surfaceDestroyed(SurfaceHolder holder) {
        SurfaceTexture previous = input;
        if (previous != null) listener.onDecoderTextureDestroyed(previous);
        super.surfaceDestroyed(holder);
        releaseDecoderTexture();
    }

    @Override public void onSurfaceCreated(GL10 gl, EGLConfig config) {
        try {
            failed = false;
            hasFrame = false;
            int[] names = {0};
            GLES20.glGenTextures(1, names, 0);
            textureID = names[0];
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureID);
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);
            int vertex = shader(GLES20.GL_VERTEX_SHADER,
                "attribute vec2 p; attribute vec2 t; uniform mat4 m; varying vec2 uv; "
                + "void main(){ gl_Position=vec4(p,0.,1.); uv=(m*vec4(t,0.,1.)).xy; }");
            int fragment = shader(GLES20.GL_FRAGMENT_SHADER,
                "#extension GL_OES_EGL_image_external : require\n"
                + "precision mediump float; varying vec2 uv; uniform samplerExternalOES image; "
                + "void main(){ gl_FragColor=texture2D(image,uv); }");
            program = GLES20.glCreateProgram();
            GLES20.glAttachShader(program, vertex);
            GLES20.glAttachShader(program, fragment);
            GLES20.glLinkProgram(program);
            GLES20.glDeleteShader(vertex);
            GLES20.glDeleteShader(fragment);
            int[] linked = {0};
            GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linked, 0);
            if (linked[0] == 0) throw new IllegalStateException(GLES20.glGetProgramInfoLog(program));
            position = GLES20.glGetAttribLocation(program, "p");
            coords = GLES20.glGetAttribLocation(program, "t");
            transform = GLES20.glGetUniformLocation(program, "m");
            GLES20.glUseProgram(program);
            GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "image"), 0);
            createDecoderTexture();
        } catch (RuntimeException error) { renderError(error); }
    }

    private int shader(int type, String source) {
        int id = GLES20.glCreateShader(type);
        GLES20.glShaderSource(id, source);
        GLES20.glCompileShader(id);
        int[] compiled = {0};
        GLES20.glGetShaderiv(id, GLES20.GL_COMPILE_STATUS, compiled, 0);
        if (compiled[0] == 0) {
            String message = GLES20.glGetShaderInfoLog(id);
            GLES20.glDeleteShader(id);
            throw new IllegalStateException(message);
        }
        return id;
    }

    private void createDecoderTexture() {
        SurfaceTexture previous = input;
        if (previous != null) previous.release();
        SurfaceTexture created = new SurfaceTexture(textureID);
        input = created;
        pending.set(false);
        hasFrame = false;
        lastTimestamp = 0;
        lastFrameNS = System.nanoTime();
        created.setOnFrameAvailableListener(value -> {
            if (input != value) return;
            pending.set(true);
            setRenderMode(RENDERMODE_CONTINUOUSLY);
            requestRender();
        }, main);
        main.post(() -> {
            if (input == created) listener.onDecoderTextureAvailable(created);
        });
    }

    @Override public void onSurfaceChanged(GL10 gl, int width, int height) {
        this.width = width;
        this.height = height;
        // A window surface may be recreated while its EGL context remains alive.
        if (input == null && !failed) {
            try { createDecoderTexture(); }
            catch (RuntimeException error) { renderError(error); }
        }
    }

    @Override public void onDrawFrame(GL10 gl) {
        GLES20.glViewport(0, 0, width, height);
        GLES20.glClearColor(0, 0, 0, 1);
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
        SurfaceTexture current = input;
        if (failed || current == null) return;
        long now = System.nanoTime();
        try {
            if (pending.getAndSet(false)) {
                current.updateTexImage();
                current.getTransformMatrix(matrix);
                hasFrame = true;
                long timestamp = current.getTimestamp();
                if (timestamp != 0 && timestamp != lastTimestamp) {
                    lastTimestamp = timestamp;
                    lastFrameNS = now;
                    listener.onVideoFrameLatched(timestamp, now);
                }
            }
            if (hasFrame) {
                GLES20.glUseProgram(program);
                GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
                GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureID);
                GLES20.glUniformMatrix4fv(transform, 1, false, matrix, 0);
                vertices.position(0);
                GLES20.glVertexAttribPointer(position, 2, GLES20.GL_FLOAT, false, 16, vertices);
                GLES20.glEnableVertexAttribArray(position);
                vertices.position(2);
                GLES20.glVertexAttribPointer(coords, 2, GLES20.GL_FLOAT, false, 16, vertices);
                GLES20.glEnableVertexAttribArray(coords);
                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
            }
            // Keep a stable EGL cadence during motion, and stop repeated GPU draws when idle.
            if (now - lastFrameNS > 500_000_000L && idlePosted.compareAndSet(false, true)) {
                main.post(() -> {
                    idlePosted.set(false);
                    if (!pending.get() && System.nanoTime() - lastFrameNS > 500_000_000L) {
                        setRenderMode(RENDERMODE_WHEN_DIRTY);
                    }
                });
            }
        } catch (RuntimeException error) { renderError(error); }
    }

    private void renderError(RuntimeException error) {
        if (failed) return;
        failed = true;
        Log.e("WireView", "GPU video render failed", error);
        main.post(() -> {
            setRenderMode(RENDERMODE_WHEN_DIRTY);
            listener.onVideoRenderError();
        });
    }
}
