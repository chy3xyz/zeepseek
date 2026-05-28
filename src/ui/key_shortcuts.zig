const builtin = @import("builtin");
const vaxis = @import("vaxis");

/// Platform-aware key-shortcut predicates and display labels.
/// On macOS, terminals supporting the Kitty keyboard protocol report
/// the Command key as `super`. We accept both Cmd and Ctrl+Shift
/// chords so the app works across all terminals.

pub const ModShift = enum { any, require, forbid };

/// Ctrl chord on Linux/Windows; ⌘ chord on macOS (when Kitty keyboard reports super).
pub fn modChord(key: vaxis.Key, codepoint: u21, shift: ModShift) bool {
    const cp = key.codepoint;
    const upper: u21 = if (codepoint >= 'a' and codepoint <= 'z')
        codepoint - 'a' + 'A'
    else if (codepoint >= 'A' and codepoint <= 'Z')
        codepoint
    else
        codepoint;
    if (cp != codepoint and cp != upper) return false;
    if (key.mods.alt) return false;
    switch (shift) {
        .require => if (!key.mods.shift) return false,
        .forbid => if (key.mods.shift) return false,
        .any => {},
    }
    if (builtin.os.tag == .macos and key.mods.super and !key.mods.ctrl) return true;
    return key.mods.ctrl and !key.mods.super;
}

pub fn isHelpToggle(key: vaxis.Key) bool {
    if (key.codepoint == vaxis.Key.f1 or key.codepoint == '?') return true;
    return modChord(key, '/', .forbid);
}

pub fn isThemeCycle(key: vaxis.Key) bool {
    return modChord(key, 't', .forbid);
}

pub fn isThinkingToggle(key: vaxis.Key) bool {
    return modChord(key, 'n', .forbid);
}

// ── Copy last message ─────────────────────────────────────────────
pub fn isCopyShortcut(key: vaxis.Key) bool {
    const is_c = key.codepoint == 'c' or key.codepoint == 'C';
    if (!is_c) return false;
    if (builtin.os.tag == .macos and key.mods.super) return true;
    return key.mods.ctrl and key.mods.shift and !key.mods.alt and !key.mods.super;
}

pub fn copyLabel() []const u8 {
    return if (builtin.os.tag == .macos) "⌘+Shift+C" else "Ctrl+Shift+C";
}

// ── Paste ─────────────────────────────────────────────────────────
pub fn isPasteShortcut(key: vaxis.Key) bool {
    const is_v = key.codepoint == 'v' or key.codepoint == 'V';
    if (!is_v) return false;
    if (builtin.os.tag == .macos and key.mods.super) return true;
    return key.mods.ctrl and !key.mods.shift and !key.mods.alt and !key.mods.super;
}

pub fn pasteLabel() []const u8 {
    return if (builtin.os.tag == .macos) "⌘+V" else "Ctrl+V";
}

// ── File tree toggle ──────────────────────────────────────────────
pub fn isFileTreeToggle(key: vaxis.Key) bool {
    const is_e = key.codepoint == 'e' or key.codepoint == 'E';
    if (!is_e) return false;
    const ctrl_shift_e = key.mods.ctrl and key.mods.shift and !key.mods.alt and !key.mods.super;
    const cmd_shift_e = key.mods.super and key.mods.shift and !key.mods.ctrl and !key.mods.alt;
    return ctrl_shift_e or cmd_shift_e;
}

pub fn fileTreeLabel() []const u8 {
    return if (builtin.os.tag == .macos) "⌘+Shift+E" else "Ctrl+Shift+E";
}

// ── User memory editor toggle ─────────────────────────────────────
pub fn isMemoryEditorToggle(key: vaxis.Key) bool {
    const is_m = key.codepoint == 'm' or key.codepoint == 'M';
    if (!is_m) return false;
    const ctrl_shift_m = key.mods.ctrl and key.mods.shift and !key.mods.alt and !key.mods.super;
    const cmd_shift_m = key.mods.super and key.mods.shift and !key.mods.ctrl and !key.mods.alt;
    return ctrl_shift_m or cmd_shift_m;
}

pub fn memoryEditorLabel() []const u8 {
    return if (builtin.os.tag == .macos) "⌘+Shift+M" else "Ctrl+Shift+M";
}

// ── Export chat ───────────────────────────────────────────────────
pub fn isExportShortcut(key: vaxis.Key) bool {
    const is_s = key.codepoint == 's' or key.codepoint == 'S';
    if (!is_s) return false;
    const ctrl_shift_s = key.mods.ctrl and key.mods.shift and !key.mods.alt and !key.mods.super;
    const cmd_shift_s = key.mods.super and key.mods.shift and !key.mods.ctrl and !key.mods.alt;
    return ctrl_shift_s or cmd_shift_s;
}

pub fn exportLabel() []const u8 {
    return if (builtin.os.tag == .macos) "⌘+Shift+S" else "Ctrl+Shift+S";
}

// ── External editor ───────────────────────────────────────────────
pub fn isExternalEditorShortcut(key: vaxis.Key) bool {
    const is_x = key.codepoint == 'x' or key.codepoint == 'X';
    if (!is_x) return false;
    const ctrl_shift_x = key.mods.ctrl and key.mods.shift and !key.mods.alt and !key.mods.super;
    const cmd_shift_x = key.mods.super and key.mods.shift and !key.mods.ctrl and !key.mods.alt;
    return ctrl_shift_x or cmd_shift_x;
}

pub fn externalEditorLabel() []const u8 {
    return if (builtin.os.tag == .macos) "⌘+Shift+X" else "Ctrl+Shift+X";
}

// ── Transcript overlay ────────────────────────────────────────────
pub fn isTranscriptToggle(key: vaxis.Key) bool {
    const is_t = key.codepoint == 't' or key.codepoint == 'T';
    if (!is_t) return false;
    const ctrl_shift_t = key.mods.ctrl and key.mods.shift and !key.mods.alt and !key.mods.super;
    const cmd_shift_t = key.mods.super and key.mods.shift and !key.mods.ctrl and !key.mods.alt;
    return ctrl_shift_t or cmd_shift_t;
}

pub fn transcriptLabel() []const u8 {
    return if (builtin.os.tag == .macos) "⌘+Shift+T" else "Ctrl+Shift+T";
}

// ── Command palette ───────────────────────────────────────────────
pub fn isCommandPalette(key: vaxis.Key) bool {
    const is_p = key.codepoint == 'p' or key.codepoint == 'P';
    if (!is_p) return false;
    if (builtin.os.tag == .macos and key.mods.super) return true;
    return key.mods.ctrl and !key.mods.shift and !key.mods.alt and !key.mods.super;
}

pub fn commandPaletteLabel() []const u8 {
    return if (builtin.os.tag == .macos) "⌘+P" else "Ctrl+P";
}

// ── New session ───────────────────────────────────────────────────
pub fn isNewSessionShortcut(key: vaxis.Key) bool {
    const is_n = key.codepoint == 'n' or key.codepoint == 'N';
    if (!is_n) return false;
    if (builtin.os.tag == .macos and key.mods.super) return true;
    return key.mods.ctrl and !key.mods.shift and !key.mods.alt and !key.mods.super;
}

pub fn newSessionLabel() []const u8 {
    return if (builtin.os.tag == .macos) "⌘+N" else "Ctrl+N";
}

// ── Text-input guard ──────────────────────────────────────────────
/// Returns true if this key should be treated as typed text rather than
/// a shortcut. Rejects any key carrying Ctrl/Alt/Super modifiers.
pub fn isTextInput(key: vaxis.Key) bool {
    return !key.mods.ctrl and !key.mods.alt and !key.mods.super;
}

// ── macOS Option-key legacy paste ─────────────────────────────────
/// macOS Option+V in legacy terminals produces the "√" character
/// (U+221A) without any modifier flags.
pub fn isMacOSOptionPaste(key: vaxis.Key) bool {
    return builtin.os.tag == .macos and
        key.codepoint == 0x221A and // √
        !key.mods.ctrl and
        !key.mods.alt and
        !key.mods.super and
        !key.mods.shift;
}
