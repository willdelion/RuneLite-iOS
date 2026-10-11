package net.kdt.pojavlaunch.uikit;

import java.awt.*;
import java.lang.reflect.Method;

/**
 * Glue between the iOS surface and the RuneLite client running on Caciocavallo.
 * Called from UIKit.java (startup) and from native code via JNI (input).
 */
public class RuneLiteSupport {
    private static Object robotPeer;
    private static Method mouseWheel;

    public static void start() {
        Thread fitter = new Thread(RuneLiteSupport::fitFramesLoop, "RuneLite-iOS-FrameFitter");
        fitter.setDaemon(true);
        fitter.start();

        if (System.getenv("RUNELITE_DEBUG_INPUT") != null) {
            Toolkit.getDefaultToolkit().addAWTEventListener(e -> {
                if (e.getID() == java.awt.event.MouseEvent.MOUSE_PRESSED || e.getID() == java.awt.event.MouseEvent.MOUSE_RELEASED) {
                    java.awt.event.MouseEvent me = (java.awt.event.MouseEvent) e;
                    System.out.println("RuneLiteSupport: " + me.paramString() + " on " + me.getComponent().getClass().getName()
                        + " screen=" + me.getXOnScreen() + "," + me.getYOnScreen());
                }
            }, AWTEvent.MOUSE_EVENT_MASK);
        }
    }

    // There is no window manager on iOS: keep every visible top-level frame covering the whole screen.
    private static void fitFramesLoop() {
        while (true) {
            try {
                Thread.sleep(500);
                final Dimension screen = Toolkit.getDefaultToolkit().getScreenSize();
                for (final Frame frame : Frame.getFrames()) {
                    if (!frame.isVisible()) {
                        continue;
                    }
                    Rectangle bounds = frame.getBounds();
                    if (bounds.x != 0 || bounds.y != 0 || bounds.width != screen.width || bounds.height != screen.height) {
                        EventQueue.invokeLater(() -> frame.setBounds(0, 0, screen.width, screen.height));
                    }
                }
            } catch (InterruptedException e) {
                return;
            } catch (Throwable e) {
                System.out.println("RuneLiteSupport: frame fit failed: " + e);
            }
        }
    }

    /** Positive amount scrolls down (zooms the camera out in OSRS). */
    public static void mouseWheel(int amount) {
        try {
            if (mouseWheel == null) {
                Class<?> input = Class.forName("com.github.caciocavallosilano.cacio.ctc.CTCAndroidInput");
                robotPeer = input.getField("mRobotPeer").get(null);
                mouseWheel = robotPeer.getClass().getMethod("mouseWheel", int.class);
            }
            mouseWheel.invoke(robotPeer, amount);
        } catch (Throwable e) {
            System.out.println("RuneLiteSupport: mouseWheel failed: " + e);
        }
    }
}
