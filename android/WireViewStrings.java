package dev.wireview.receiver;

import java.util.Locale;

final class WireViewStrings {
    private static final boolean CHINESE = "zh".equals(Locale.getDefault().getLanguage());

    private WireViewStrings() {}

    static String waitingForConnection() {
        return CHINESE ? "等待连接…" : "Waiting for connection…";
    }

    static String disconnected() {
        return CHINESE ? "已断开连接" : "Disconnected";
    }
}
