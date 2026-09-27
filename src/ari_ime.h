// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
#ifndef ARI_IME_ARI_IME_H
#define ARI_IME_ARI_IME_H

#include <string>
#include <utility>

#include <fcitx-config/configuration.h>
#include <fcitx-config/iniparser.h>
#include <fcitx-config/option.h>
#include <fcitx-config/rawconfig.h>
#include <fcitx-utils/i18n.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/addonmanager.h>
#include <fcitx/inputcontextproperty.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/instance.h>

#include "buffer.h"
#include "layout.h"

class AriImeEngine;

namespace ari_ime {

// Every option's description doubles as its label in the configuration UI, and
// the KDE System Settings module lays that label out on a single unwrapped
// line. A paragraph-length description therefore stretches the page well past
// the right edge of the window. Keep descriptions to a short label and hang the
// full explanation off a tooltip instead.
//
// fcitx::ToolTipAnnotation cannot be used directly here: it has no default
// constructor (which FCITX_CONFIGURATION's option templates want) and it cannot
// be combined with the enum I18N annotations the combo-box options need. This
// wrapper does both, holding whichever annotation the option already carries.
//
// `base_` is held by composition rather than inheritance, and is mutable: fcitx
// declares an annotation's dumpDescription() const in some releases and
// non-const in others (its own Option stores the annotation in a mutable member
// for exactly that reason). Composing sidesteps the difference, so this header
// builds against the fcitx5 of every distribution the project targets rather
// than only the newest one. `Base` must therefore be stateless and default
// constructible — true of NoAnnotation and of the enum I18N annotations.
template <typename Base = fcitx::NoAnnotation>
struct TooltipAnnotation {
    TooltipAnnotation() = default;
    explicit TooltipAnnotation(std::string tooltip)
        : tooltip_(std::move(tooltip)) {}

    bool skipDescription() const { return false; }
    bool skipSave() const { return false; }
    void dumpDescription(fcitx::RawConfig &config) const {
        base_.dumpDescription(config); // Enum/EnumI18n, when Base supplies them
        if (!tooltip_.empty()) {
            config.setValueByPath("Tooltip", tooltip_);
        }
    }

private:
    mutable Base base_{};
    std::string tooltip_;
};

// Shorthands so the option declarations below stay readable. The key-list one
// is spelled out rather than using fcitx::KeyListOptionWithAnnotation, which is
// newer than the plain fcitx::KeyListOption this file used before; the expansion
// is identical and needs only long-standing fcitx5 names.
template <typename T, typename Base = fcitx::NoAnnotation>
using TooltipOption = fcitx::OptionWithAnnotation<T, TooltipAnnotation<Base>>;
using KeyListTooltipOption =
    fcitx::Option<fcitx::KeyList, fcitx::ListConstrain<fcitx::KeyConstrain>,
                  fcitx::DefaultMarshaller<fcitx::KeyList>,
                  TooltipAnnotation<>>;

} // namespace ari_ime

// User-facing configuration, surfaced in fcitx5-configtool. Keyboard layout
// choices are backed by layout.cpp so key classification and chewing's KB type
// stay in sync. Descriptions are short labels; see TooltipAnnotation above for
// why the details live in tooltips.
FCITX_CONFIGURATION(
    AriImeConfig,
    ari_ime::TooltipOption<ari_ime::KeyboardLayout,
                           ari_ime::KeyboardLayoutI18NAnnotation>
        keyboardLayout{
        this, "KeyboardLayout", _("Keyboard layout"),
        ari_ime::KeyboardLayout::Default, {}, {},
        ari_ime::TooltipAnnotation<ari_ime::KeyboardLayoutI18NAnnotation>(
            _("Bopomofo key arrangement. This drives both Ari's own key classification and libchewing's keyboard type, so they always match."))};
    ari_ime::TooltipOption<bool> fullWidthPunctuation{
        this, "FullWidthPunctuation", _("Always use full-width punctuation"),
        false, {}, {},
        ari_ime::TooltipAnnotation<>(
            _("Use full-width Chinese punctuation without a modifier. Off keeps ordinary punctuation literal; the configured Chinese punctuation shortcut plus a punctuation key produces its Chinese form temporarily."))};
    ari_ime::TooltipOption<ari_ime::ChinesePunctuationShortcut,
                           ari_ime::ChinesePunctuationShortcutI18NAnnotation>
        chinesePunctuationShortcut{
        this, "ChinesePunctuationShortcut",
        _("Chinese punctuation shortcut"),
        ari_ime::ChinesePunctuationShortcut::ControlShift, {}, {},
        ari_ime::TooltipAnnotation<
            ari_ime::ChinesePunctuationShortcutI18NAnnotation>(
            _("Modifier used for temporary Chinese punctuation (default Ctrl+Shift). Choose Alt+Shift or another option if an application uses the default gesture. Alt+[ and Alt+] are reserved for Chinese corner quotes."))};
    ari_ime::TooltipOption<bool> spaceCandidateMode{
        this, "SpaceCandidateMode", _("Space opens candidates"), false, {}, {},
        ari_ime::TooltipAnnotation<>(
            _("Use Space to open Chinese candidates after a complete syllable. Off keeps Ari's mixed-input Space-as-tone-one and literal-space behavior; Enter remains the commit key."))};
    ari_ime::TooltipOption<ari_ime::CandidateArrowKeys,
                           ari_ime::CandidateArrowKeysI18NAnnotation>
        candidateArrowKeys{
        this, "CandidateArrowKeys", _("Left/Right in the candidate window"),
        ari_ime::CandidateArrowKeys::MoveCursor, {}, {},
        ari_ime::TooltipAnnotation<ari_ime::CandidateArrowKeysI18NAnnotation>(
            _("What Left and Right do while candidates are open: move to the neighbouring character's candidates, or turn pages within the focused character's list, cycling at both ends like libchewing's own window. Whichever you do not choose stays available — PageUp/PageDown always turn pages, and Escape returns to the caret where Left and Right always move."))};
    ari_ime::TooltipOption<ari_ime::CaretAfterPick,
                           ari_ime::CaretAfterPickI18NAnnotation>
        caretAfterPick{
        this, "CaretAfterPick", _("Caret after picking a candidate"),
        ari_ime::CaretAfterPick::NextCharacter, {}, {},
        ari_ime::TooltipAnnotation<ari_ime::CaretAfterPickI18NAnnotation>(
            _("Where the caret goes once a candidate is chosen: on the character right after the text the pick rewrote, so a mid-sentence correction keeps editing there, or back at the end of the pre-edit to resume appending."))};
    ari_ime::TooltipOption<ari_ime::LiteralKeyReinterpret,
                           ari_ime::LiteralKeyReinterpretI18NAnnotation>
        literalKeyReinterpret{
        this, "LiteralKeyReinterpret", _("Up arrow on a literal character"),
        ari_ime::LiteralKeyReinterpret::Syllable, {}, {},
        ari_ime::TooltipAnnotation<ari_ime::LiteralKeyReinterpretI18NAnnotation>(
            _("What Up does to a literal English or punctuation character in the pre-edit. Merging folds it together with the next few characters into one Chinese character when they form a complete syllable, recovering cases like catsu3 into cat plus 你. Showing the Bopomofo symbol replaces just that one key with the symbol it stands for (1 becomes ㄅ) as ordinary text, the way ASUS's mixed input does; the symbol is a finished character, so the next key you type follows it."))};
    ari_ime::KeyListTooltipOption reconversionKey{
        this, "ReconversionKey", _("Reconversion shortcut"),
        {fcitx::Key("Control+Alt+R")}, fcitx::KeyListConstrain(), {},
        ari_ime::TooltipAnnotation<>(
            _("Re-open selected short Chinese text for candidate correction. The default is Control+Alt+R; clear it to avoid reserving a shortcut."))};
    ari_ime::TooltipOption<bool> autoLearn{
        this, "AutoLearn", _("Learn accepted choices locally"), true, {}, {},
        ari_ime::TooltipAnnotation<>(
            _("Adapt the personal dictionary to the Chinese choices you accept. Turn this off to keep it unchanged; sensitive fields never learn regardless of this setting."))};
    ari_ime::TooltipOption<bool> showStatusLine{
        this, "ShowStatusLine", _("Show composition status"), false, {}, {},
        ari_ime::TooltipAnnotation<>(
            _("Show composition status text in the auxiliary line (for example 中 · 大千 · 半形標點) while composing."))};
    ari_ime::TooltipOption<bool> showPendingZhuyin{
        this, "ShowPendingZhuyin", _("Show pending Bopomofo"), false, {}, {},
        ari_ime::TooltipAnnotation<>(
            _("Show the Bopomofo symbols of the pending syllable in a small box near the cursor while typing."))};
    ari_ime::KeyListTooltipOption fullWidthPunctuationToggle{
        this, "FullWidthPunctuationToggle",
        _("Full-width punctuation toggle"), {}, fcitx::KeyListConstrain(), {},
        ari_ime::TooltipAnnotation<>(
            _("Optional shortcut to turn full-width punctuation on and off. Empty by default so no application shortcut is reserved; set for example Control+period. A modifier is required."))};);

// Per-input-context state, owned by fcitx and created on demand.
class AriImeState : public fcitx::InputContextProperty {
public:
    AriImeState() = default;
    Buffer buffer;
    // Set once we have warned the user that the 注音 engine failed to load, so
    // the transient hint is not shown on every keystroke.
    bool engineErrorNotified = false;
    // The selected text is deleted from the client while reconversion is
    // active. Escape/focus reset restores it instead of losing user text.
    bool reconversionActive = false;
    std::string reconversionText;
};

class AriImeEngine : public fcitx::InputMethodEngineV2 {
public:
    explicit AriImeEngine(fcitx::Instance *instance);

    void keyEvent(const fcitx::InputMethodEntry &entry,
                  fcitx::KeyEvent &keyEvent) override;
    void reset(const fcitx::InputMethodEntry &entry,
               fcitx::InputContextEvent &event) override;

    // --- Configuration (fcitx5-configtool) ---
    const fcitx::Configuration *getConfig() const override { return &config_; }
    void setConfig(const fcitx::RawConfig &config) override {
        config_.load(config, true);
        applyConfig();
        fcitx::safeSaveAsIni(config_, "conf/ari-ime.conf");
    }
    void reloadConfig() override {
        fcitx::readAsIni(config_, "conf/ari-ime.conf");
        applyConfig();
    }

private:
    ari_ime::KeyboardLayout applyConfig();
    void updateUI(fcitx::InputContext *ic, Buffer &buffer);
    void applyResult(fcitx::InputContext *ic, Buffer &buffer,
                     const KeyResult &result);
    bool beginReconversion(fcitx::InputContext *ic, AriImeState &state);
    // Current clipboard contents (Ctrl+V), or empty if the clipboard module is
    // unavailable. Loads the clipboard addon on demand.
    std::string clipboardText(fcitx::InputContext *ic);

    fcitx::Instance *instance_;
    fcitx::FactoryFor<AriImeState> factory_;
    AriImeConfig config_;
};

class AriImeEngineFactory : public fcitx::AddonFactory {
public:
    fcitx::AddonInstance *create(fcitx::AddonManager *manager) override {
        return new AriImeEngine(manager->instance());
    }
};

#endif // ARI_IME_ARI_IME_H
