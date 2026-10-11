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

        Thread defaults = new Thread(RuneLiteSupport::applyDefaultConfig, "RuneLite-iOS-Defaults");
        defaults.setDaemon(true);
        defaults.start();

        if (System.getenv("RUNELITE_DEBUG_INPUT") != null) {
            Toolkit.getDefaultToolkit().addAWTEventListener(e -> {
                if (e.getID() == java.awt.event.MouseEvent.MOUSE_PRESSED || e.getID() == java.awt.event.MouseEvent.MOUSE_RELEASED) {
                    java.awt.event.MouseEvent me = (java.awt.event.MouseEvent) e;
                    System.out.println("RuneLiteSupport: " + me.paramString() + " on " + me.getComponent().getClass().getName()
                        + " screen=" + me.getXOnScreen() + "," + me.getYOnScreen());
                    for (Component c = me.getComponent(); c != null; c = c.getParent()) {
                        System.out.println("RuneLiteSupport:   " + c.getClass().getName() + " " + c.getBounds());
                    }
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
                    // Push Caciocavallo's window decorations off-screen so the content covers the whole display
                    Insets in = frame.getInsets();
                    final Rectangle target = new Rectangle(-in.left, -in.top,
                        screen.width + in.left + in.right, screen.height + in.top + in.bottom);
                    Rectangle bounds = frame.getBounds();
                    if (!bounds.equals(target)) {
                        EventQueue.invokeLater(() -> frame.setBounds(target));
                    } else if (frame.getComponentCount() > 0) {
                        // Caciocavallo doesn't relayout after a programmatic resize; the content keeps its old size
                        Insets insets = frame.getInsets();
                        Component content = frame.getComponent(0);
                        if (content.getWidth() != bounds.width - insets.left - insets.right
                            || content.getHeight() != bounds.height - insets.top - insets.bottom) {
                            EventQueue.invokeLater(() -> {
                                frame.invalidate();
                                frame.validate();
                            });
                        }
                    }
                }
            } catch (InterruptedException e) {
                return;
            } catch (Throwable e) {
                System.out.println("RuneLiteSupport: frame fit failed: " + e);
            }
        }
    }

    // Phone-friendly defaults, applied once per RuneLite profile so the player can change them afterwards
    private static final String DEFAULTS_VERSION = "4";
    private static final String[][] DEFAULT_CONFIG = {
        // Fill the whole wide phone screen; fixed mode gets stretched horizontally
        {"stretchedmode", "keepAspectRatio", "false"},
        {"stretchedmode", "increasedPerformance", "true"},
        // No window title bar on a phone screen (takes effect on the next launch)
        {"runelite", "uiEnableCustomChrome", "false"},
    };
    // Plugin class simple name -> enabled
    private static final String[][] DEFAULT_PLUGINS = {
        // Scale the game to fill the screen instead of drawing fixed mode at 765x503
        {"StretchedModePlugin", "true"},
        // The GPU plugin needs desktop OpenGL, which doesn't exist here
        {"GpuPlugin", "false"},
    };

    private static void applyDefaultConfig() {
        try {
            // RuneLite runs from the launcher's URLClassLoader, which it publishes for Swing
            ClassLoader loader = null;
            Object injector = null;
            for (int i = 0; i < 600 && injector == null; i++) {
                Thread.sleep(500);
                if (loader == null) {
                    loader = (ClassLoader) javax.swing.UIManager.get("ClassLoader");
                    if (loader == null) continue;
                }
                injector = loader.loadClass("net.runelite.client.RuneLite").getMethod("getInjector").invoke(null);
            }
            if (injector == null) {
                System.out.println("RuneLiteSupport: RuneLite injector not found, skipping defaults");
                return;
            }

            Class<?> configManagerClass = loader.loadClass("net.runelite.client.config.ConfigManager");
            // Call through the public Injector interface; the implementation class isn't accessible
            Object configManager = loader.loadClass("com.google.inject.Injector")
                .getMethod("getInstance", Class.class).invoke(injector, configManagerClass);
            Method get = configManagerClass.getMethod("getConfiguration", String.class, String.class);
            Method set = configManagerClass.getMethod("setConfiguration", String.class, String.class, String.class);

            // The injector exists before the profile is loaded; wait until configuration can be read
            Object applied = null;
            for (int i = 0; ; i++) {
                try {
                    applied = get.invoke(configManager, "runeliteios", "defaultsVersion");
                    break;
                } catch (java.lang.reflect.InvocationTargetException e) {
                    if (i >= 240) throw e;
                    Thread.sleep(500);
                }
            }
            if (DEFAULTS_VERSION.equals(applied)) {
                return;
            }
            for (String[] entry : DEFAULT_CONFIG) {
                set.invoke(configManager, entry[0], entry[1], entry[2]);
            }
            setPluginDefaults(loader, injector);
            set.invoke(configManager, "runeliteios", "defaultsVersion", DEFAULTS_VERSION);
            System.out.println("RuneLiteSupport: applied iOS default config");
        } catch (Throwable e) {
            Throwable cause = e instanceof java.lang.reflect.InvocationTargetException ? e.getCause() : e;
            System.out.println("RuneLiteSupport: applying defaults failed: " + cause);
            cause.printStackTrace(System.out);
        }
    }

    // Changing the plugin's config key alone doesn't start it; go through PluginManager like the config panel does
    private static void setPluginDefaults(ClassLoader loader, Object injector) throws Exception {
        Class<?> pluginManagerClass = loader.loadClass("net.runelite.client.plugins.PluginManager");
        Class<?> pluginClass = loader.loadClass("net.runelite.client.plugins.Plugin");
        final Object pluginManager = loader.loadClass("com.google.inject.Injector")
            .getMethod("getInstance", Class.class).invoke(injector, pluginManagerClass);
        Method getPlugins = pluginManagerClass.getMethod("getPlugins");
        Method setEnabled = pluginManagerClass.getMethod("setPluginEnabled", pluginClass, boolean.class);
        final Method start = pluginManagerClass.getMethod("startPlugin", pluginClass);
        final Method stop = pluginManagerClass.getMethod("stopPlugin", pluginClass);

        // Plugins are registered a bit after the config loads
        java.util.Collection<?> plugins = null;
        for (int i = 0; i < 240; i++) {
            plugins = (java.util.Collection<?>) getPlugins.invoke(pluginManager);
            if (!plugins.isEmpty()) break;
            Thread.sleep(500);
        }
        for (final Object plugin : plugins) {
            for (String[] entry : DEFAULT_PLUGINS) {
                if (!plugin.getClass().getSimpleName().equals(entry[0])) continue;
                final boolean enable = Boolean.parseBoolean(entry[1]);
                setEnabled.invoke(pluginManager, plugin, enable);
                EventQueue.invokeLater(() -> {
                    try {
                        (enable ? start : stop).invoke(pluginManager, plugin);
                    } catch (Throwable e) {
                        System.out.println("RuneLiteSupport: toggling " + plugin + " failed: " + e);
                    }
                });
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
