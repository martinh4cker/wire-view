package dev.wireview.receiver;

import java.util.Locale;

final class WireViewStrings {
    private static final boolean CHINESE = "zh".equals(Locale.getDefault().getLanguage());

    private WireViewStrings() {}

    static String waitingForMac() {
        return CHINESE ? "等待 Mac 有线连接…" : "Waiting for a wired connection to Mac…";
    }

    static String renderFailed() {
        return CHINESE ? "GPU 视频渲染失败，请重新打开接收端。"
            : "GPU video rendering failed. Reopen the receiver app.";
    }
}
