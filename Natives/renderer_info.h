#pragma once

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

// OpenGL renderers: the library LWJGL gets as org.lwjgl.opengl.libname and that the
// GL bridges create their context from.
#define RENDERER_NAME_AUTO "auto"
#define RENDERER_NAME_GL4ES "libgl4es_114.dylib"
#define RENDERER_NAME_MTL_ANGLE "libtinygl4angle.dylib"
#define RENDERER_NAME_MOBILEGLUES "libmobileglues.dylib"
#define RENDERER_NAME_MOBILEGL "libMobileGL.dylib"
#define RENDERER_NAME_VK_ZINK "libOSMesa.8.dylib"

// Vulkan drivers: the library the game's Vulkan backend and SDL present through.
#define RENDERER_NAME_MOLTENVK "libMoltenVK.dylib"
#define RENDERER_NAME_KOSMICKRISP "libvulkan.dylib"
// Kosmic Krisp is a raw Mesa build without a loader; libame_vulkan.dylib adds the
// entry points LWJGL asks for and dlopens the driver named by AME_VULKAN_DRIVER.
#define RENDERER_FILE_KOSMICKRISP "libame_vulkan.dylib"
#define VULKAN_DRIVER_ENV "AME_VULKAN_DRIVER"

typedef enum {
    AME_RENDERER_UNKNOWN,
    AME_RENDERER_AUTO,
    AME_RENDERER_GL4ES,
    AME_RENDERER_ANGLE,
    AME_RENDERER_MOBILEGLUES,
    AME_RENDERER_MOBILEGL,
    AME_RENDERER_ZINK
} ame_renderer_t;

typedef enum {
    AME_VULKAN_DRIVER_AUTO,
    AME_VULKAN_DRIVER_MOLTENVK,
    AME_VULKAN_DRIVER_KOSMICKRISP
} ame_vulkan_driver_t;

static inline ame_renderer_t ame_renderer_from_name(const char *name)
{
    if (!name) return AME_RENDERER_UNKNOWN;
    if (!strcmp(name, RENDERER_NAME_AUTO)) return AME_RENDERER_AUTO;
    if (!strcmp(name, RENDERER_NAME_GL4ES)) return AME_RENDERER_GL4ES;
    if (!strcmp(name, RENDERER_NAME_MTL_ANGLE)) return AME_RENDERER_ANGLE;
    if (!strcmp(name, RENDERER_NAME_MOBILEGLUES)) return AME_RENDERER_MOBILEGLUES;
    if (!strcmp(name, RENDERER_NAME_MOBILEGL)) return AME_RENDERER_MOBILEGL;
    if (!strncmp(name, "libOSMesa", 9)) return AME_RENDERER_ZINK;
    return AME_RENDERER_UNKNOWN;
}

static inline const char *ame_renderer_file_name(ame_renderer_t r)
{
    switch (r) {
        case AME_RENDERER_GL4ES: return RENDERER_NAME_GL4ES;
        case AME_RENDERER_ANGLE: return RENDERER_NAME_MTL_ANGLE;
        case AME_RENDERER_MOBILEGLUES: return RENDERER_NAME_MOBILEGLUES;
        case AME_RENDERER_MOBILEGL: return RENDERER_NAME_MOBILEGL;
        case AME_RENDERER_ZINK: return RENDERER_NAME_VK_ZINK;
        default: return RENDERER_NAME_AUTO;
    }
}

// A Vulkan driver used to be stored where the renderer lives, JavaLauncher and the
// preference migration turn those values into ANGLE + a Vulkan driver.
static inline bool ame_renderer_name_is_vulkan_driver(const char *name)
{
    if (!name) return false;
    return !strcmp(name, RENDERER_NAME_MOLTENVK) || !strcmp(name, RENDERER_NAME_KOSMICKRISP);
}

// stored renderer value -> the OpenGL renderer that should actually run
static inline ame_renderer_t ame_renderer_from_stored_name(const char *name)
{
    if (ame_renderer_name_is_vulkan_driver(name)) return AME_RENDERER_ANGLE;
    return ame_renderer_from_name(name);
}

// renderers that expose a desktop GL context, gl4es is the only one that asks for GLES
static inline bool ame_renderer_is_desktop_gl(ame_renderer_t r)
{
    return r == AME_RENDERER_ANGLE || r == AME_RENDERER_MOBILEGLUES || r == AME_RENDERER_MOBILEGL;
}

// these ship their own EGL entry points, everything else goes through ANGLE's
static inline bool ame_renderer_owns_egl(ame_renderer_t r)
{
    return r == AME_RENDERER_MOBILEGLUES || r == AME_RENDERER_MOBILEGL;
}

// everything that presents through ANGLE sizes its drawable from bounds * contentsScale
static inline bool ame_renderer_uses_angle(ame_renderer_t r)
{
    return r == AME_RENDERER_AUTO || r == AME_RENDERER_GL4ES || r == AME_RENDERER_ANGLE || r == AME_RENDERER_MOBILEGLUES;
}

// OpenGL renderers that render through Vulkan themselves. Zink has its MoltenVK baked
// in (it dlopens libMoltenVK.dylib by name), MobileGL loads the driver picked in the
// settings through the libame_vulkan.dylib dispatch shim.
static inline bool ame_renderer_consumes_vulkan(ame_renderer_t r)
{
    return r == AME_RENDERER_ZINK || r == AME_RENDERER_MOBILEGL;
}

static inline ame_vulkan_driver_t ame_vulkan_driver_from_name(const char *name)
{
    if (!name || !*name) return AME_VULKAN_DRIVER_AUTO;
    if (!strcmp(name, RENDERER_NAME_AUTO)) return AME_VULKAN_DRIVER_AUTO;
    if (!strcmp(name, RENDERER_NAME_MOLTENVK)) return AME_VULKAN_DRIVER_MOLTENVK;
    if (!strcmp(name, RENDERER_NAME_KOSMICKRISP)) return AME_VULKAN_DRIVER_KOSMICKRISP;
    // the launcher hands the driver around by path as well
    if (strstr(name, RENDERER_NAME_MOLTENVK)) return AME_VULKAN_DRIVER_MOLTENVK;
    if (strstr(name, RENDERER_NAME_KOSMICKRISP)) return AME_VULKAN_DRIVER_KOSMICKRISP;
    return AME_VULKAN_DRIVER_AUTO;
}

// Auto means MoltenVK: it is the driver that ships as the stable default
static inline ame_vulkan_driver_t ame_vulkan_driver_resolve(ame_vulkan_driver_t driver)
{
    return driver == AME_VULKAN_DRIVER_KOSMICKRISP
        ? AME_VULKAN_DRIVER_KOSMICKRISP : AME_VULKAN_DRIVER_MOLTENVK;
}

// stored value, the same string the settings picker uses
static inline const char *ame_vulkan_driver_name(ame_vulkan_driver_t driver)
{
    return ame_vulkan_driver_resolve(driver) == AME_VULKAN_DRIVER_KOSMICKRISP
        ? RENDERER_NAME_KOSMICKRISP : RENDERER_NAME_MOLTENVK;
}

static inline const char *ame_vulkan_driver_display_name(ame_vulkan_driver_t driver)
{
    return ame_vulkan_driver_resolve(driver) == AME_VULKAN_DRIVER_KOSMICKRISP
        ? "KosmicKrisp" : "MoltenVK";
}

// bundled file of the Vulkan driver itself
static inline const char *ame_vulkan_driver_file(ame_vulkan_driver_t driver)
{
    return ame_vulkan_driver_name(driver);
}

// bundled file LWJGL should load, Kosmic Krisp goes through the loader shim
static inline const char *ame_vulkan_driver_load_file(ame_vulkan_driver_t driver)
{
    return ame_vulkan_driver_resolve(driver) == AME_VULKAN_DRIVER_KOSMICKRISP
        ? RENDERER_FILE_KOSMICKRISP : RENDERER_NAME_MOLTENVK;
}

// Kosmic Krisp's WSI sizes the layer's drawableSize itself when it creates a swapchain,
// MoltenVK expects the app to set it, so writing it from outside fights the driver
static inline bool ame_vulkan_driver_sizes_layer(ame_vulkan_driver_t driver)
{
    return ame_vulkan_driver_resolve(driver) == AME_VULKAN_DRIVER_KOSMICKRISP;
}

// the driver JavaLauncher picked, JavaLauncher sets AME_VULKAN_DRIVER before the JVM starts
static inline ame_vulkan_driver_t ame_vulkan_driver_selected(void)
{
    return ame_vulkan_driver_resolve(ame_vulkan_driver_from_name(getenv(VULKAN_DRIVER_ENV)));
}

static inline bool isMobileGLRenderer(const char *renderer)
{
    return ame_renderer_from_stored_name(renderer) == AME_RENDERER_MOBILEGL;
}
