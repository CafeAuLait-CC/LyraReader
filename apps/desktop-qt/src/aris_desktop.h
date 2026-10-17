#pragma once
#include <cstddef>
#include <cstdint>

// Owned Rust allocations: free each Buffer exactly once using buffer_free.
// Output buffers must be zero initialized; calls do not free previous contents.
// All document operations may block and must run on a worker, not the UI thread.
extern "C" {
struct ArisDesktopDocument;
struct ArisBuffer { std::uint8_t *data; std::size_t len; };
struct ArisBitmap {
    std::uint32_t width, height, stride;
    double scale;
    ArisBuffer pixels;
};
ArisDesktopDocument *aris_reader_desktop_open(const std::uint8_t *path, std::size_t path_len,
    const std::uint8_t *password, std::size_t password_len, ArisBuffer *error);
void aris_reader_desktop_close(ArisDesktopDocument *document);
bool aris_reader_desktop_info(const ArisDesktopDocument *document, ArisBuffer *output, ArisBuffer *error);
bool aris_reader_desktop_render(const ArisDesktopDocument *document, std::uint32_t page, double scale,
    ArisBitmap *output, ArisBuffer *error);
void aris_reader_desktop_buffer_free(ArisBuffer buffer);
double aris_reader_desktop_fit_width(double page_width, double viewport_width);
double aris_reader_desktop_zoom_offset(double offset, double anchor, double old_zoom, double new_zoom);
}
