package dev.wireview.receiver;

import android.util.Log;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;
import java.io.DataOutputStream;
import java.io.IOException;
import java.net.Socket;
import java.util.ArrayDeque;

final class TouchControl {
    static final int DOWN = 1, DRAG = 2, UP = 3, SCROLL = 4, CANCEL = 5, GESTURE = 8;
    private static final int SPACE_LEFT = 1, SPACE_RIGHT = 2, MISSION_CONTROL = 3,
        APP_WINDOWS = 4, PREVIOUS_APP = 5, NEXT_APP = 6;

    // Only this worker writes WTS3 feedback. Never block the UI or codec callback on USB.
    static final class Feedback implements AutoCloseable {
        private final ArrayDeque<Long> pending = new ArrayDeque<>();
        private final Socket socket;
        private boolean closed;
        private boolean reportedTouch;

        Feedback(DataOutputStream output, Socket socket, String token) {
            this.socket = socket;
            if (token != null && token.matches("[0-9a-f]{28}")) {
                pending.add(0x8600000000000000L | Long.parseLong(token.substring(0, 14), 16));
                pending.add(0x8700000000000000L | Long.parseLong(token.substring(14), 16));
            }
            new Thread(() -> write(output), "wireview-feedback").start();
        }

        synchronized void send(long word) {
            if (closed) return;
            if (action(word) == DRAG && !pending.isEmpty() && action(pending.peekLast()) == DRAG) {
                pending.removeLast();
            }
            if (pending.size() >= 128) {
                close(); // Host releases any held button on disconnect.
                return;
            }
            pending.add(word);
            notifyAll();
        }

        private static int action(long word) { return word < 0 ? (int) ((word >>> 56) & 127) : 0; }

        private void write(DataOutputStream output) {
            try {
                while (true) {
                    long word;
                    synchronized (this) {
                        while (!closed && pending.isEmpty()) wait();
                        if (closed) return;
                        word = pending.removeFirst();
                    }
                    output.writeLong(word);
                    int type = action(word);
                    if (!reportedTouch && ((type >= DOWN && type <= CANCEL) || type == GESTURE)) {
                        reportedTouch = true;
                        Log.i("WireView", "Sent first touch event");
                    }
                }
            } catch (IOException | InterruptedException e) {
                close();
            }
        }

        @Override public synchronized void close() {
            closed = true;
            pending.clear();
            notifyAll();
            try { socket.close(); } catch (IOException ignored) { }
        }
    }

    private Feedback gesture;
    private boolean started, dragging, scrolling, blocked, scrollCommitted;
    private int swipeFingers;
    private final int[] swipeIds = new int[4];
    private final float[] swipeX = new float[4], swipeY = new float[4];
    private float startX, startY, lastX, lastY, carryX, carryY;

    boolean handle(View video, MotionEvent event, Feedback link) {
        int action = event.getActionMasked();
        if (gesture != link) {
            cancel();
            gesture = link;
        }
        if (link == null) return true;
        float width = video.getWidth(), height = video.getHeight();
        if (width <= 1 || height <= 1) { cancel(); return true; }

        if (action == MotionEvent.ACTION_DOWN) {
            cancel();
            gesture = link;
            startX = event.getX();
            startY = event.getY();
            started = inside(startX, startY, width, height);
        } else if (action == MotionEvent.ACTION_CANCEL) {
            cancel();
        } else if (started && !blocked) {
            if (action == MotionEvent.ACTION_POINTER_DOWN) {
                if (dragging) send(CANCEL, 0, 0, 0, 0);
                dragging = false;
                int count = event.getPointerCount();
                boolean valid = count <= 4 && !scrollCommitted;
                for (int i = 0; valid && i < count; i++) {
                    valid = inside(event.getX(i), event.getY(i), width, height);
                }
                if (count == 2) {
                    scrolling = valid;
                    blocked = !valid;
                    lastX = startX = (event.getX(0) + event.getX(1)) / 2;
                    lastY = startY = (event.getY(0) + event.getY(1)) / 2;
                    carryX = carryY = 0;
                } else {
                    scrolling = false;
                    blocked = !valid;
                    swipeFingers = valid ? count : 0;
                    for (int i = 0; i < swipeFingers; i++) {
                        swipeIds[i] = event.getPointerId(i);
                        swipeX[i] = event.getX(i);
                        swipeY[i] = event.getY(i);
                    }
                }
            } else if (action == MotionEvent.ACTION_POINTER_UP) {
                if (swipeFingers >= 3) finishSwipe(video, event, width, height);
                blocked = true; // Commit once and ignore remaining fingers until the next gesture.
            } else if (action == MotionEvent.ACTION_MOVE && scrolling && event.getPointerCount() == 2) {
                float x = (event.getX(0) + event.getX(1)) / 2;
                float y = (event.getY(0) + event.getY(1)) / 2;
                if (!scrollCommitted && Math.hypot(x - startX, y - startY)
                        < ViewConfiguration.get(video.getContext()).getScaledTouchSlop()) return true;
                scrollCommitted = true;
                carryX += x - lastX;
                carryY += y - lastY;
                lastX = x;
                lastY = y;
                int dx = delta(carryX), dy = delta(carryY);
                carryX -= (int) carryX;
                carryY -= (int) carryY;
                if (dx != 0 || dy != 0) send(SCROLL, normalized(x, width), normalized(y, height), dx, dy);
            } else if (action == MotionEvent.ACTION_MOVE && !scrolling && swipeFingers == 0) {
                float x = event.getX(), y = event.getY();
                if (!dragging && Math.hypot(x - startX, y - startY)
                        >= ViewConfiguration.get(video.getContext()).getScaledTouchSlop()) {
                    send(DOWN, normalized(startX, width), normalized(startY, height), 0, 0);
                    dragging = true;
                }
                if (dragging) send(DRAG, normalized(x, width), normalized(y, height), 0, 0);
            } else if (action == MotionEvent.ACTION_UP && !scrolling) {
                if (!dragging && !inside(event.getX(), event.getY(), width, height)) { cancel(); return true; }
                int x = normalized(event.getX(), width), y = normalized(event.getY(), height);
                if (!dragging) send(DOWN, x, y, 0, 0);
                send(UP, x, y, 0, 0);
                dragging = false;
                started = false;
                video.performClick();
            }
        }
        return true;
    }

    void cancel() {
        if (dragging && gesture != null) send(CANCEL, 0, 0, 0, 0);
        dragging = started = scrolling = blocked = scrollCommitted = false;
        swipeFingers = 0;
        gesture = null;
    }

    private void finishSwipe(View video, MotionEvent event, float width, float height) {
        if (event.getPointerCount() != swipeFingers) return;
        float dx = 0, dy = 0, x = 0, y = 0;
        for (int i = 0; i < swipeFingers; i++) {
            int index = event.findPointerIndex(swipeIds[i]);
            if (index < 0) return;
            x += event.getX(index);
            y += event.getY(index);
            dx += event.getX(index) - swipeX[i];
            dy += event.getY(index) - swipeY[i];
        }
        dx /= swipeFingers;
        dy /= swipeFingers;
        boolean horizontal = Math.abs(dx) >= Math.abs(dy);
        float primary = horizontal ? dx : dy;
        float cross = horizontal ? dy : dx;
        float threshold = 40 * video.getResources().getDisplayMetrics().density;
        if (Math.abs(primary) < threshold || Math.abs(primary) < 1.4f * Math.abs(cross)) return;
        for (int i = 0; i < swipeFingers; i++) {
            int index = event.findPointerIndex(swipeIds[i]);
            float distance = horizontal ? event.getX(index) - swipeX[i] : event.getY(index) - swipeY[i];
            if (distance * Math.signum(primary) < threshold / 3) return;
        }

        int command;
        if (swipeFingers == 4) {
            if (!horizontal) return;
            command = dx < 0 ? NEXT_APP : PREVIOUS_APP;
        } else if (horizontal) {
            command = dx < 0 ? SPACE_RIGHT : SPACE_LEFT;
        } else {
            command = dy < 0 ? MISSION_CONTROL : APP_WINDOWS;
        }
        send(GESTURE, normalized(x / swipeFingers, width), normalized(y / swipeFingers, height), command, 0);
    }

    private static boolean inside(float x, float y, float width, float height) {
        return x >= 0 && y >= 0 && x < width && y < height;
    }

    private static int delta(float value) { return Math.max(-127, Math.min(127, (int) value)); }

    private static int normalized(float value, float extent) {
        return Math.round(65535 * Math.max(0, Math.min(1, value / (extent - 1))));
    }

    private void send(int action, int x, int y, int dx, int dy) {
        gesture.send(Long.MIN_VALUE | ((long) action << 56) | ((long) x << 40) | ((long) y << 24)
                     | ((long) (dx & 255) << 16) | ((long) (dy & 255) << 8));
    }
}
