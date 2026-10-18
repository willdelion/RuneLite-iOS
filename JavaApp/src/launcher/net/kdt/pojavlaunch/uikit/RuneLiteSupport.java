package net.kdt.pojavlaunch.uikit;

import java.awt.*;
import java.lang.reflect.Method;

/**
 * Glue between the iOS surface and the RuneLite client running on Caciocavallo.
 * Called from UIKit.java (startup) and from native code via JNI (input).
 */
public class RuneLiteSupport {

    // Mouse button (1-3) native code is currently pressing; see MouseButtonFixQueue
    private static volatile int activeButton = java.awt.event.MouseEvent.BUTTON1;

    /** Called from native code right before it presses a mouse button. */
    public static void setActiveButton(int button) {
        activeButton = button;
    }

    /**
     * Caciocavallo's robot only converts button masks correctly for the left button: a middle press arrives as
     * button 1 + Alt Graph, and some presses arrive with no button at all (AWT then throws "button doesn't
     * exist 0" and Swing's mouse grab breaks). Rewrite button events to the button native code actually pressed.
     */
    private static class MouseButtonFixQueue extends EventQueue {
        private static final int BUTTON_DOWN_MASKS = java.awt.event.InputEvent.BUTTON1_DOWN_MASK
            | java.awt.event.InputEvent.BUTTON2_DOWN_MASK | java.awt.event.InputEvent.BUTTON3_DOWN_MASK
            | java.awt.event.InputEvent.ALT_GRAPH_DOWN_MASK;

        private boolean buttonHeld;

        @Override
        protected void dispatchEvent(AWTEvent event) {
            if (event instanceof java.awt.event.MouseEvent && !(event instanceof java.awt.event.MouseWheelEvent)) {
                java.awt.event.MouseEvent e = (java.awt.event.MouseEvent) event;
                int id = e.getID();
                if (id == java.awt.event.MouseEvent.MOUSE_PRESSED) buttonHeld = true;
                if (id == java.awt.event.MouseEvent.MOUSE_RELEASED) buttonHeld = false;
                // Movement with a button held must be a drag (e.g. middle-button camera rotation)
                if (id == java.awt.event.MouseEvent.MOUSE_MOVED && buttonHeld) id = java.awt.event.MouseEvent.MOUSE_DRAGGED;
                boolean held = id == java.awt.event.MouseEvent.MOUSE_PRESSED || id == java.awt.event.MouseEvent.MOUSE_DRAGGED;
                boolean buttonEvent = held || id == java.awt.event.MouseEvent.MOUSE_RELEASED || id == java.awt.event.MouseEvent.MOUSE_CLICKED;
                if (buttonEvent) {
                    int button = activeButton;
                    int modifiers = e.getModifiersEx() & ~BUTTON_DOWN_MASKS;
                    // Its right-button mask conversion also leaks a bogus Shift (old BUTTON3 bits)
                    if (button == java.awt.event.MouseEvent.BUTTON3) modifiers &= ~java.awt.event.InputEvent.SHIFT_DOWN_MASK;
                    if (held) modifiers |= java.awt.event.InputEvent.getMaskForButton(button);
                    event = new java.awt.event.MouseEvent(e.getComponent(), id, e.getWhen(), modifiers,
                        e.getX(), e.getY(), e.getXOnScreen(), e.getYOnScreen(), e.getClickCount(),
                        id == java.awt.event.MouseEvent.MOUSE_PRESSED && button == java.awt.event.MouseEvent.BUTTON3,
                        id == java.awt.event.MouseEvent.MOUSE_DRAGGED ? java.awt.event.MouseEvent.NOBUTTON : button);
                }
            }
            super.dispatchEvent(event);
        }
    }

    public static void start() {
        Toolkit.getDefaultToolkit().getSystemEventQueue().push(new MouseButtonFixQueue());

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
                    for (Window w : Window.getWindows()) {
                        String title = w instanceof Dialog ? ((Dialog) w).getTitle() : w instanceof Frame ? ((Frame) w).getTitle() : "";
                        System.out.println("RuneLiteSupport:   window " + w.getClass().getName() + " '" + title + "' visible=" + w.isVisible()
                            + " showing=" + w.isShowing() + " " + w.getBounds());
                        if (w instanceof javax.swing.JDialog && w.isShowing()) {
                            dumpText(((javax.swing.JDialog) w).getContentPane());
                        }
                    }
                    for (Component c = me.getComponent(); c != null; c = c.getParent()) {
                        System.out.println("RuneLiteSupport:   " + c.getClass().getName() + " " + c.getBounds());
                    }
                }
                if (e instanceof java.awt.event.MouseWheelEvent) {
                    java.awt.event.MouseWheelEvent we = (java.awt.event.MouseWheelEvent) e;
                    System.out.println("RuneLiteSupport: wheel " + we.getWheelRotation() + " on " + we.getComponent().getClass().getName());
                }
            }, AWTEvent.MOUSE_EVENT_MASK | AWTEvent.MOUSE_WHEEL_EVENT_MASK);
        }
    }

    // There is no window manager on iOS: keep every visible top-level frame covering the whole screen.
    private static void fitFramesLoop() {
        int tick = 0;
        while (true) {
            try {
                Thread.sleep(500);
                if (++tick % 2 == 0) {
                    EventQueue.invokeLater(RuneLiteSupport::repaintSwingAroundGame);
                }
                final Dimension screen = Toolkit.getDefaultToolkit().getScreenSize();
                raiseNewDialogs();
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
                                frame.repaint();
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
    private static final String DEFAULTS_VERSION = "8";
    private static final String[][] DEFAULT_CONFIG = {
        // Stretch fixed mode over the whole wide phone screen, with smooth (bilinear) filtering
        {"stretchedmode", "keepAspectRatio", "false"},
        {"stretchedmode", "increasedPerformance", "false"},
        // Plugin Hub plugins load after this runs; their enabled flag is read from config when they do
        {"runelite", "camerasmoothingplugin", "false"},
        // No window title bar on a phone screen (takes effect on the next launch)
        {"runelite", "uiEnableCustomChrome", "false"},
    };
    // Plugin class simple name -> enabled
    private static final String[][] DEFAULT_PLUGINS = {
        // Scale the game to fill the screen instead of drawing fixed mode at 765x503
        {"StretchedModePlugin", "true"},
        // The GPU plugin needs desktop OpenGL, which doesn't exist here
        {"GpuPlugin", "false"},
        // Rewrites camera targets every frame, making touch camera drags snap back
        {"CameraSmoothingPlugin", "false"},
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

            initClient(loader, injector);
            retryPluginHub(loader, injector);

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

        // Plugins are registered gradually after the config loads; wait until the list stops growing.
        // Plugin Hub plugins (camera smoothing) come later and are covered by DEFAULT_CONFIG instead.
        java.util.Collection<?> plugins = null;
        int lastSize = -1, stable = 0;
        for (int i = 0; i < 240 && stable < 6; i++) {
            Thread.sleep(500);
            plugins = (java.util.Collection<?>) getPlugins.invoke(pluginManager);
            stable = !plugins.isEmpty() && plugins.size() == lastSize ? stable + 1 : 0;
            lastSize = plugins.size();
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

    private static final java.util.Map<Window, Boolean> raisedDialogs = new java.util.WeakHashMap<>();

    /**
     * Caciocavallo can leave a newly shown dialog (e.g. a modal message box) stacked under the main frame:
     * invisible, yet modal and swallowing touches. Bring each new dialog to the front once.
     */
    private static void raiseNewDialogs() {
        for (final Window w : Window.getWindows()) {
            if (w instanceof Dialog && w.isShowing() && !raisedDialogs.containsKey(w)) {
                raisedDialogs.put(w, Boolean.TRUE);
                EventQueue.invokeLater(() -> {
                    w.toFront();
                    w.repaint();
                });
            }
        }
    }

    /**
     * Caciocavallo misses some Swing repaints (e.g. RuneLite's sidebar icons after a layout change stay blank
     * until touched). Periodically repaint the Swing parts of the window, skipping the game canvas, which
     * draws itself every frame.
     */
    private static void repaintSwingAroundGame() {
        for (Frame frame : Frame.getFrames()) {
            if (frame.isShowing()) {
                repaintExceptCanvas(frame);
            }
        }
    }

    private static boolean repaintExceptCanvas(Container parent) {
        boolean containsCanvas = false;
        for (Component c : parent.getComponents()) {
            if (!c.isShowing()) continue;
            if (c instanceof Canvas) {
                containsCanvas = true;
            } else if (c instanceof Container && repaintExceptCanvas((Container) c)) {
                containsCanvas = true;
            } else {
                c.repaint();
            }
        }
        return containsCanvas;
    }

    private static void dumpText(Container parent) {
        for (Component c : parent.getComponents()) {
            if (c instanceof javax.swing.JLabel) System.out.println("RuneLiteSupport:     label: " + ((javax.swing.JLabel) c).getText());
            if (c instanceof javax.swing.text.JTextComponent) System.out.println("RuneLiteSupport:     text: " + ((javax.swing.text.JTextComponent) c).getText());
            if (c instanceof javax.swing.AbstractButton) System.out.println("RuneLiteSupport:     button: " + ((javax.swing.AbstractButton) c).getText());
            if (c instanceof Container) dumpText((Container) c);
        }
    }

    /** True when the screen point is over the game itself rather than RuneLite's Swing UI. */
    public static boolean isOverGame(int x, int y) {
        try {
            for (Frame frame : Frame.getFrames()) {
                if (!frame.isShowing()) continue;
                Point origin = frame.getLocationOnScreen();
                Component hit = javax.swing.SwingUtilities.getDeepestComponentAt(frame, x - origin.x, y - origin.y);
                return hit instanceof Canvas;
            }
        } catch (Throwable e) {
            System.out.println("RuneLiteSupport: isOverGame failed: " + e);
        }
        return true;
    }

    // Max distance (in screen pixels) a tap may miss a Swing button by and still hit it
    private static final int SNAP_RADIUS = 28;
    // Width of the strip along the game canvas' right edge that may snap to the sidebar
    private static final int CANVAS_EDGE_BAND = 12;

    /**
     * Fingers are much less precise than a mouse and RuneLite's sidebar/panel buttons are tiny:
     * if a tap lands near (but not on) a Swing button, move it to that button's centre.
     * Called from native code; returns the point packed as (x << 32) | y.
     */
    public static long snapToButton(int x, int y) {
        long original = ((long) x << 32) | (y & 0xffffffffL);
        try {
            for (Frame frame : Frame.getFrames()) {
                if (!frame.isShowing()) continue;
                Point origin = frame.getLocationOnScreen();
                Point p = new Point(x - origin.x, y - origin.y);
                Component hit = javax.swing.SwingUtilities.getDeepestComponentAt(frame, p.x, p.y);
                // Leave exact button hits alone
                if (hit instanceof javax.swing.AbstractButton
                    || javax.swing.SwingUtilities.getAncestorOfClass(javax.swing.AbstractButton.class, hit) != null) {
                    return original;
                }
                int minX = Integer.MIN_VALUE;
                if (hit instanceof Canvas) {
                    // Taps on the game stay on the game, except in a thin band along its right edge next to the
                    // sidebar, where they may only snap to buttons outside the canvas
                    Rectangle game = javax.swing.SwingUtilities.convertRectangle(hit.getParent(), hit.getBounds(), frame);
                    int right = game.x + game.width;
                    if (p.x < right - CANVAS_EDGE_BAND) {
                        return original;
                    }
                    minX = right;
                }
                Rectangle[] best = new Rectangle[1];
                findNearestButton(frame, frame, p, minX, best, new double[]{SNAP_RADIUS});
                if (best[0] == null) return original;
                Rectangle r = best[0];
                return ((long) (origin.x + r.x + r.width / 2) << 32) | ((origin.y + r.y + r.height / 2) & 0xffffffffL);
            }
        } catch (Throwable e) {
            System.out.println("RuneLiteSupport: snapToButton failed: " + e);
        }
        return original;
    }

    private static void findNearestButton(Frame frame, Container parent, Point p, int minX, Rectangle[] best, double[] bestDistance) {
        for (Component c : parent.getComponents()) {
            if (!c.isShowing()) continue;
            if (c instanceof javax.swing.AbstractButton) {
                if (!c.isEnabled()) continue;
                Rectangle r = javax.swing.SwingUtilities.convertRectangle(c.getParent(), c.getBounds(), frame);
                if (r.x < minX) continue;
                double dx = Math.max(Math.max(r.x - p.x, 0), p.x - (r.x + r.width));
                double dy = Math.max(Math.max(r.y - p.y, 0), p.y - (r.y + r.height));
                double d = Math.hypot(dx, dy);
                if (d < bestDistance[0]) {
                    bestDistance[0] = d;
                    best[0] = r;
                }
            } else if (c instanceof Container) {
                findNearestButton(frame, (Container) c, p, minX, best, bestDistance);
            }
        }
    }

    // net.runelite.api.Client and the methods we drive directly
    private static volatile Object client;
    private static Method getFps;

    private static void initClient(ClassLoader loader, Object injector) throws Exception {
        Class<?> clientClass = loader.loadClass("net.runelite.api.Client");
        Object c = loader.loadClass("com.google.inject.Injector").getMethod("getInstance", Class.class).invoke(injector, clientClass);
        getFps = clientClass.getMethod("getFPS");
        final Method setUnlockedFps = clientClass.getMethod("setUnlockedFps", boolean.class);
        final Method setUnlockedFpsTarget = clientClass.getMethod("setUnlockedFpsTarget", int.class);
        client = c;

        // Render between game ticks instead of the default 50 fps cap
        Thread fps = new Thread(() -> {
            while (true) {
                try {
                    setUnlockedFps.invoke(client, true);
                    setUnlockedFpsTarget.invoke(client, TARGET_FPS);
                    System.out.println("RuneLiteSupport: fps " + getFps.invoke(client));
                    Thread.sleep(10000);
                } catch (InterruptedException e) {
                    return;
                } catch (Throwable e) {
                    System.out.println("RuneLiteSupport: fps setup failed: " + e);
                    return;
                }
            }
        }, "RuneLite-iOS-Fps");
        fps.setDaemon(true);
        fps.start();
    }

    private static final int TARGET_FPS = 60;

    /**
     * On the phone, large Plugin Hub responses often stall inside the VPN tunnel while small requests and the
     * game itself work. Give the hub's OkHttp client long timeouts and keep the last good (signed) manifest
     * on disk, serving it when the network fetch fails. RuneLite still verifies the manifest signature.
     */
    private static void patchPluginHubClient(final ClassLoader loader, Object externalManager) throws Exception {
        Class<?> hubClientClass = loader.loadClass("net.runelite.client.externalplugins.ExternalPluginClient");
        Object hubClient = null;
        for (java.lang.reflect.Field f : externalManager.getClass().getDeclaredFields()) {
            if (f.getType() == hubClientClass) {
                f.setAccessible(true);
                hubClient = f.get(externalManager);
            }
        }
        if (hubClient == null) throw new IllegalStateException("ExternalPluginClient not found");

        Class<?> okClientClass = loader.loadClass("okhttp3.OkHttpClient");
        java.lang.reflect.Field okField = null;
        for (java.lang.reflect.Field f : hubClientClass.getDeclaredFields()) {
            if (f.getType() == okClientClass) okField = f;
        }
        okField.setAccessible(true);
        Object okClient = okField.get(hubClient);

        final Class<?> interceptorClass = loader.loadClass("okhttp3.Interceptor");
        final Class<?> chainClass = loader.loadClass("okhttp3.Interceptor$Chain");
        final Class<?> requestClass = loader.loadClass("okhttp3.Request");
        final Class<?> responseClass = loader.loadClass("okhttp3.Response");
        final Class<?> bodyClass = loader.loadClass("okhttp3.ResponseBody");
        final Class<?> mediaTypeClass = loader.loadClass("okhttp3.MediaType");
        final Class<?> protocolClass = loader.loadClass("okhttp3.Protocol");
        final java.io.File cacheDir = new java.io.File(System.getProperty("user.home"), ".runelite/ios-pluginhub-cache");

        Object interceptor = java.lang.reflect.Proxy.newProxyInstance(loader, new Class<?>[]{interceptorClass}, (proxy, method, args) -> {
            switch (method.getName()) {
                case "intercept": break;
                case "hashCode": return System.identityHashCode(proxy);
                case "equals": return proxy == args[0];
                default: return "RuneLiteIOSManifestCache";
            }
            Object chain = args[0];
            Object request = chainClass.getMethod("request").invoke(chain);
            String url = String.valueOf(requestClass.getMethod("url").invoke(request));
            Method proceed = chainClass.getMethod("proceed", requestClass);
            if (!url.contains("/manifest/")) {
                try {
                    return proceed.invoke(chain, request);
                } catch (java.lang.reflect.InvocationTargetException e) {
                    throw e.getCause();
                }
            }
            java.io.File cached = new java.io.File(cacheDir, url.substring(url.lastIndexOf('/') + 1));
            try {
                Object response = proceed.invoke(chain, request);
                if ((int) responseClass.getMethod("code").invoke(response) != 200) return response;
                Object body = responseClass.getMethod("body").invoke(response);
                Object contentType = bodyClass.getMethod("contentType").invoke(body);
                byte[] bytes = (byte[]) bodyClass.getMethod("bytes").invoke(body);
                cacheDir.mkdirs();
                java.nio.file.Files.write(cached.toPath(), bytes);
                Object builder = responseClass.getMethod("newBuilder").invoke(response);
                Object newBody = bodyClass.getMethod("create", mediaTypeClass, byte[].class).invoke(null, contentType, bytes);
                builder.getClass().getMethod("body", bodyClass).invoke(builder, newBody);
                return builder.getClass().getMethod("build").invoke(builder);
            } catch (Throwable e) {
                Throwable cause = e instanceof java.lang.reflect.InvocationTargetException ? e.getCause() : e;
                if (!cached.isFile()) throw cause;
                System.out.println("RuneLiteSupport: " + url + " failed (" + cause + "), using cached manifest");
                byte[] bytes = java.nio.file.Files.readAllBytes(cached.toPath());
                Object builder = loader.loadClass("okhttp3.Response$Builder").getConstructor().newInstance();
                Class<?> b = builder.getClass();
                b.getMethod("request", requestClass).invoke(builder, request);
                b.getMethod("protocol", protocolClass).invoke(builder, Enum.valueOf((Class) protocolClass, "HTTP_1_1"));
                b.getMethod("code", int.class).invoke(builder, 200);
                b.getMethod("message", String.class).invoke(builder, "OK (cached)");
                b.getMethod("body", bodyClass).invoke(builder, bodyClass.getMethod("create", mediaTypeClass, byte[].class).invoke(null, null, bytes));
                return b.getMethod("build").invoke(builder);
            }
        });

        Object builder = okClientClass.getMethod("newBuilder").invoke(okClient);
        Class<?> b = builder.getClass();
        b.getMethod("connectTimeout", long.class, java.util.concurrent.TimeUnit.class).invoke(builder, 30L, java.util.concurrent.TimeUnit.SECONDS);
        b.getMethod("readTimeout", long.class, java.util.concurrent.TimeUnit.class).invoke(builder, 120L, java.util.concurrent.TimeUnit.SECONDS);
        b.getMethod("addInterceptor", interceptorClass).invoke(builder, interceptor);
        okField.set(hubClient, b.getMethod("build").invoke(builder));
        System.out.println("RuneLiteSupport: Plugin Hub client patched (cache " + cacheDir + ")");
    }

    /**
     * RuneLite fetches the Plugin Hub manifest once at startup and loads no hub plugins if that request fails
     * (e.g. a SocketTimeoutException while the phone's network/VPN is still settling). Keep retrying in the
     * background until the installed hub plugins are actually running.
     */
    private static void retryPluginHub(ClassLoader loader, Object injector) throws Exception {
        Class<?> managerClass = loader.loadClass("net.runelite.client.externalplugins.ExternalPluginManager");
        Class<?> pluginManagerClass = loader.loadClass("net.runelite.client.plugins.PluginManager");
        Method getInstance = loader.loadClass("com.google.inject.Injector").getMethod("getInstance", Class.class);
        final Object externalManager = getInstance.invoke(injector, managerClass);
        final Object pluginManager = getInstance.invoke(injector, pluginManagerClass);
        final Method installed = managerClass.getMethod("getInstalledExternalPlugins");
        final Method update = managerClass.getMethod("update");
        final Method getJarData = managerClass.getMethod("getJarData", Class.class);
        final Method getPlugins = pluginManagerClass.getMethod("getPlugins");
        try {
            patchPluginHubClient(loader, externalManager);
        } catch (Throwable e) {
            System.out.println("RuneLiteSupport: patching Plugin Hub client failed: " + e);
        }

        Thread retry = new Thread(() -> {
            // Give the normal startup load time to finish first
            for (int attempt = 0; attempt < 10; attempt++) {
                try {
                    Thread.sleep(attempt == 0 ? 20000 : 30000);
                    if (((java.util.List<?>) installed.invoke(externalManager)).isEmpty()) return;
                    boolean anyLoaded = false;
                    for (Object plugin : (java.util.Collection<?>) getPlugins.invoke(pluginManager)) {
                        if (getJarData.invoke(null, plugin.getClass()) != null) {
                            anyLoaded = true;
                            break;
                        }
                    }
                    if (anyLoaded) return;
                    System.out.println("RuneLiteSupport: Plugin Hub plugins not loaded, retrying (attempt " + (attempt + 1) + ")");
                    update.invoke(externalManager);
                } catch (InterruptedException e) {
                    return;
                } catch (Throwable e) {
                    System.out.println("RuneLiteSupport: Plugin Hub retry failed: " + e);
                }
            }
        }, "RuneLite-iOS-PluginHubRetry");
        retry.setDaemon(true);
        retry.start();
    }

    /**
     * Positive amount scrolls down (zooms the camera out in OSRS). Caciocavallo's robot ignores the wheel, so
     * post the event to whatever is under the given screen point; Swing forwards it to enclosing scroll panes.
     */
    public static void mouseWheel(int x, int y, int amount) {
        try {
            for (Frame frame : Frame.getFrames()) {
                if (!frame.isShowing()) continue;
                Point origin = frame.getLocationOnScreen();
                Component target = javax.swing.SwingUtilities.getDeepestComponentAt(frame, x - origin.x, y - origin.y);
                if (target == null) return;
                Point local = new Point(x, y);
                javax.swing.SwingUtilities.convertPointFromScreen(local, target);
                Toolkit.getDefaultToolkit().getSystemEventQueue().postEvent(new java.awt.event.MouseWheelEvent(
                    target, java.awt.event.MouseEvent.MOUSE_WHEEL, System.currentTimeMillis(), 0,
                    local.x, local.y, x, y, 0, false, java.awt.event.MouseWheelEvent.WHEEL_UNIT_SCROLL, 3, amount));
                return;
            }
        } catch (Throwable e) {
            System.out.println("RuneLiteSupport: mouseWheel failed: " + e);
        }
    }
}
