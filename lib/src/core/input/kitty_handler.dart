import 'package:xterm2/src/core/input/event.dart';
import 'package:xterm2/src/core/input/keys.dart';

/// Translates key presses using Kitty's progressive keyboard protocol.
///
/// Flutter exposes text entry separately from logical key presses, so this
/// handler only consumes textual keys when the active protocol mode requires
/// an escape sequence. Textual keys that keep their traditional bytes continue
/// through the keytab input handler; the functional keys do not — see
/// [_functionalSequence] for why the protocol has to own them outright, even
/// where the bytes it produces are the legacy ones.
class KittyKeyboardInputHandler implements TerminalInputHandler {
  const KittyKeyboardInputHandler();

  static const _disambiguateEscapeCodes = 0x01;
  static const _reportEventTypes = 0x02;
  static const _reportAlternateKeys = 0x04;
  static const _reportAllKeysAsEscapeCodes = 0x08;
  static const _reportAssociatedText = 0x10;

  @override
  String? call(TerminalKeyboardEvent event) {
    final mode = event.state.kittyKeyboardMode;
    final kittySequenceEnabled = mode &
            (_disambiguateEscapeCodes |
                _reportEventTypes |
                _reportAllKeysAsEscapeCodes) !=
        0;
    if (!kittySequenceEnabled) {
      return null;
    }

    // DIVERGENCE (Karmashala): kitty's `encode_key` opens with exactly this
    // test — a release is dropped outright unless *report event types* was
    // asked for, whatever the key. Without it a pane that only disambiguated
    // saw a second sequence for every F13-F24 and keypad keystroke, because
    // the two code paths below answer a release the same way they answer a
    // press.
    if (event.type == TerminalKeyEventType.release &&
        mode & _reportEventTypes == 0) {
      return null;
    }

    final specialCode = _specialKeyCode(event.key);
    if (specialCode != null) {
      return _sequence(specialCode, event);
    }

    final numpadCode = _numpadKeyCode(event.key);
    if (numpadCode != null) {
      return _sequence(numpadCode, event);
    }

    final functionalSequence = _functionalSequence(event, mode);
    if (functionalSequence != null) {
      return functionalSequence;
    }

    final controlCode = _controlKeyCode(event.key);
    if (controlCode != null && _shouldUseLegacyControlCode(event, mode)) {
      return String.fromCharCode(controlCode);
    }

    if (_shouldEncodeControlKey(event, mode)) {
      if (controlCode != null) {
        return _sequence(controlCode, event);
      }
    }

    final characterCode = _characterKeyCode(event);
    if (characterCode == null) {
      return null;
    }
    if (!_shouldEncodeCharacter(event, mode)) {
      return null;
    }

    var payload = characterCode.toString();
    final reportsAlternateKeys = mode & _reportAlternateKeys != 0;
    final alternateCode = _alternateCharacterCode(event, characterCode);
    if (reportsAlternateKeys && alternateCode != null) {
      payload = '$payload:$alternateCode';
    }

    return _sequence(payload, event);
  }

  bool _shouldEncodeControlKey(TerminalKeyboardEvent event, int mode) {
    if (mode & _reportAllKeysAsEscapeCodes != 0) {
      return true;
    }
    if (event.key == TerminalKey.escape) {
      return mode & (_disambiguateEscapeCodes | _reportEventTypes) != 0;
    }
    if (event.type == TerminalKeyEventType.release &&
        mode & _reportEventTypes != 0) {
      if (mode & _reportAllKeysAsEscapeCodes != 0) {
        return true;
      }
      return event.ctrl || event.alt || event.shift || event.superKey;
    }
    if (mode & _disambiguateEscapeCodes == 0) {
      return false;
    }
    return event.ctrl || event.alt || event.shift || event.superKey;
  }

  bool _shouldEncodeCharacter(TerminalKeyboardEvent event, int mode) {
    if (mode & _reportAllKeysAsEscapeCodes != 0) {
      return true;
    }
    if (event.type == TerminalKeyEventType.release &&
        mode & _reportEventTypes != 0) {
      return true;
    }
    if (mode & _disambiguateEscapeCodes == 0) {
      return false;
    }
    return event.ctrl || event.alt || event.superKey;
  }

  bool _shouldUseLegacyControlCode(TerminalKeyboardEvent event, int mode) {
    if (event.key == TerminalKey.escape) {
      return false;
    }
    if (event.type == TerminalKeyEventType.release) {
      return false;
    }
    if (mode & _reportAllKeysAsEscapeCodes != 0) {
      return false;
    }
    if (event.ctrl || event.alt || event.shift || event.superKey) {
      return false;
    }
    return true;
  }

  String _sequence(
    Object payload,
    TerminalKeyboardEvent event, {
    String terminator = 'u',
  }) {
    final modifiers = _encodedModifiers(event);
    final reportsEventType =
        event.state.kittyKeyboardMode & _reportEventTypes != 0;
    final eventType = switch (event.type) {
      TerminalKeyEventType.press => null,
      TerminalKeyEventType.repeat when reportsEventType => 2,
      TerminalKeyEventType.release when reportsEventType => 3,
      _ => null,
    };
    final associatedText = _associatedText(event);
    final hasExtendedParameters =
        modifiers != 1 || eventType != null || associatedText != null;
    if (!hasExtendedParameters) {
      return '\x1b[$payload$terminator';
    }

    final modifierParameter =
        switch (modifiers == 1 && associatedText != null) {
      true => '',
      false => '$modifiers',
    };
    final eventParameter = switch (eventType) {
      null => modifierParameter,
      final value => '$modifierParameter:$value',
    };
    final textParameter = switch (associatedText) {
      null => '',
      final value => ';$value',
    };
    return '\x1b[$payload;$eventParameter$textParameter$terminator';
  }

  int _encodedModifiers(TerminalKeyboardEvent event) {
    var modifiers = 1;
    if (event.shift) {
      modifiers += 1;
    }
    if (event.alt) {
      modifiers += 2;
    }
    if (event.ctrl) {
      modifiers += 4;
    }
    if (event.superKey) {
      modifiers += 8;
    }
    if (event.capsLock) {
      modifiers += 64;
    }
    if (event.numLock) {
      modifiers += 128;
    }
    return modifiers;
  }

  int? _characterKeyCode(TerminalKeyboardEvent event) {
    final key = event.key;
    if (key.index >= TerminalKey.keyA.index &&
        key.index <= TerminalKey.keyZ.index) {
      return key.index - TerminalKey.keyA.index + 97;
    }
    if (key.index >= TerminalKey.digit1.index &&
        key.index <= TerminalKey.digit9.index) {
      return key.index - TerminalKey.digit1.index + 49;
    }
    final mappedCode = switch (key) {
      TerminalKey.digit0 => 48,
      TerminalKey.space => 32,
      TerminalKey.minus => 45,
      TerminalKey.equal => 61,
      TerminalKey.bracketLeft => 91,
      TerminalKey.bracketRight => 93,
      TerminalKey.backslash || TerminalKey.intlBackslash => 92,
      TerminalKey.semicolon => 59,
      TerminalKey.quote => 39,
      TerminalKey.backquote => 96,
      TerminalKey.comma => 44,
      TerminalKey.period => 46,
      TerminalKey.slash => 47,
      _ => null,
    };
    if (mappedCode != null) {
      return mappedCode;
    }

    final text = event.text;
    if (text == null || text.runes.isEmpty) {
      return null;
    }
    final character = String.fromCharCode(text.runes.first);
    final unshiftedCharacter = switch (event.shift) {
      true => character.toLowerCase(),
      false => character,
    };
    return unshiftedCharacter.runes.first;
  }

  int? _alternateCharacterCode(
    TerminalKeyboardEvent event,
    int characterCode,
  ) {
    final text = event.text;
    if (text == null) {
      final isLetter = event.key.index >= TerminalKey.keyA.index &&
          event.key.index <= TerminalKey.keyZ.index;
      if (event.shift && isLetter) {
        return characterCode - 32;
      }
      return null;
    }
    if (text.runes.length != 1) {
      return null;
    }
    final alternateCode = text.runes.first;
    if (alternateCode == characterCode) {
      return null;
    }
    if (_isControlCodepoint(alternateCode)) {
      return null;
    }
    return alternateCode;
  }

  String? _associatedText(TerminalKeyboardEvent event) {
    final mode = event.state.kittyKeyboardMode;
    if (mode & _reportAssociatedText == 0 ||
        event.type == TerminalKeyEventType.release) {
      return null;
    }
    if (event.ctrl || event.alt || event.superKey) {
      return null;
    }
    final text = event.text;
    if (text == null || text.isEmpty) {
      return null;
    }
    final codepoints = text.runes.toList(growable: false);
    final hasControlCharacter = codepoints.any(_isControlCodepoint);
    if (hasControlCharacter) {
      return null;
    }
    return codepoints.join(':');
  }

  bool _isControlCodepoint(int codepoint) {
    return codepoint < 0x20 || (codepoint >= 0x7f && codepoint <= 0x9f);
  }

  /// Encodes the keys the protocol keeps in `CSI number ; modifiers <trailer>`
  /// form rather than in `CSI u`.
  ///
  /// DIVERGENCE (Karmashala): upstream answered here only for a repeat or a
  /// release, leaving every *press* to the keytab. That reads as harmless —
  /// for an unmodified cursor key the keytab's sequence is byte-identical to
  /// kitty's, right down to kitty omitting a key number of `1` — but the
  /// keytab answers from terminal state the protocol says to ignore, and from
  /// a modifier set it cannot express. Measured against `key_encoding.c`
  /// (`encode_function_key`), four things were wrong once any enhancement was
  /// on:
  ///
  /// * **Cursor key mode.** kitty reaches its `SS3` forms only when
  ///   `legacy_mode` — no *disambiguate*, no *report event types*, no *report
  ///   all keys* — so under the protocol `End` is `CSI F`, never `SS3 F`. The
  ///   keytab has no idea the protocol exists and kept sending `ESC O F` to a
  ///   program that had asked not to receive it.
  /// * **F1-F4** lose `SS3` with them: `CSI P`, `CSI Q`, `CSI S`.
  /// * **F3** is `CSI 13 ~`, not `CSI R`, because `CSI R` is a cursor position
  ///   report. The spec removed the `CSI R` form for exactly that collision.
  /// * **The lock and super modifiers.** `convert_glfw_mods` masks caps lock
  ///   and num lock off only when no enhancement is set, so with the protocol
  ///   on `End` with num lock is `CSI 1;129 F`; the keytab's modifier
  ///   substitution stops at ctrl+alt+shift and drops super entirely.
  ///
  /// With no modifiers, no locks and cursor key mode off — the ordinary case —
  /// the bytes are unchanged, which is the point: this fixes what a program
  /// asked for without moving what it did not.
  String? _functionalSequence(TerminalKeyboardEvent event, int mode) {
    final mapping = switch (event.key) {
      TerminalKey.pageUp => (5, '~'),
      TerminalKey.pageDown => (6, '~'),
      TerminalKey.insert => (2, '~'),
      TerminalKey.delete => (3, '~'),
      TerminalKey.home => (1, 'H'),
      TerminalKey.end => (1, 'F'),
      TerminalKey.arrowLeft => (1, 'D'),
      TerminalKey.arrowRight => (1, 'C'),
      TerminalKey.arrowUp => (1, 'A'),
      TerminalKey.arrowDown => (1, 'B'),
      TerminalKey.f1 => (1, 'P'),
      TerminalKey.f2 => (1, 'Q'),
      TerminalKey.f3 => (13, '~'),
      TerminalKey.f4 => (1, 'S'),
      TerminalKey.f5 => (15, '~'),
      TerminalKey.f6 => (17, '~'),
      TerminalKey.f7 => (18, '~'),
      TerminalKey.f8 => (19, '~'),
      TerminalKey.f9 => (20, '~'),
      TerminalKey.f10 => (21, '~'),
      TerminalKey.f11 => (23, '~'),
      TerminalKey.f12 => (24, '~'),
      _ => null,
    };
    if (mapping == null) {
      return null;
    }
    return _functionalKeySequence(mapping.$1, mapping.$2, event, mode);
  }

  /// kitty's `serialize` for a functional key, whose two omissions carry the
  /// whole backwards compatibility of the protocol.
  ///
  /// A key number of `1` is written only when a parameter follows it, and the
  /// parameter list is written only when there is a modifier or an event type
  /// to report — so an unmodified `Right` is the three bytes `ESC [ C` that
  /// terminfo has always named, in kitty mode and out of it alike.
  String _functionalKeySequence(
    int number,
    String terminator,
    TerminalKeyboardEvent event,
    int mode,
  ) {
    final reportsEventType = mode & _reportEventTypes != 0;
    final eventType = switch (event.type) {
      TerminalKeyEventType.repeat when reportsEventType => 2,
      TerminalKeyEventType.release when reportsEventType => 3,
      _ => null,
    };
    final modifiers = _encodedModifiers(event);
    if (modifiers == 1 && eventType == null) {
      return switch (number) {
        1 => '\x1b[$terminator',
        _ => '\x1b[$number$terminator',
      };
    }
    final parameters = switch (eventType) {
      null => '$modifiers',
      final value => '$modifiers:$value',
    };
    return '\x1b[$number;$parameters$terminator';
  }

  int? _controlKeyCode(TerminalKey key) {
    return switch (key) {
      TerminalKey.tab => 9,
      TerminalKey.enter => 13,
      TerminalKey.escape => 27,
      TerminalKey.space => 32,
      TerminalKey.backspace => 127,
      _ => null,
    };
  }

  int? _specialKeyCode(TerminalKey key) {
    if (key.index >= TerminalKey.f13.index &&
        key.index <= TerminalKey.f24.index) {
      return key.index - TerminalKey.f13.index + 57376;
    }
    return switch (key) {
      TerminalKey.capsLock => 57358,
      TerminalKey.scrollLock => 57359,
      TerminalKey.numLock => 57360,
      TerminalKey.printScreen => 57361,
      TerminalKey.pause => 57362,
      TerminalKey.contextMenu => 57363,
      TerminalKey.mediaPlay => 57428,
      TerminalKey.mediaPause => 57429,
      TerminalKey.mediaPlayPause => 57430,
      TerminalKey.mediaStop => 57432,
      TerminalKey.mediaFastForward => 57433,
      TerminalKey.mediaRewind => 57434,
      TerminalKey.mediaTrackNext => 57435,
      TerminalKey.mediaTrackPrevious => 57436,
      TerminalKey.mediaRecord => 57437,
      TerminalKey.audioVolumeDown => 57438,
      TerminalKey.audioVolumeUp => 57439,
      TerminalKey.audioVolumeMute => 57440,
      TerminalKey.shiftLeft => 57441,
      TerminalKey.controlLeft => 57442,
      TerminalKey.altLeft => 57443,
      TerminalKey.metaLeft => 57444,
      TerminalKey.shiftRight => 57447,
      TerminalKey.controlRight => 57448,
      TerminalKey.altRight => 57449,
      TerminalKey.metaRight => 57450,
      _ => null,
    };
  }

  int? _numpadKeyCode(TerminalKey key) {
    if (key.index >= TerminalKey.numpad1.index &&
        key.index <= TerminalKey.numpad9.index) {
      return key.index - TerminalKey.numpad1.index + 57400;
    }
    return switch (key) {
      TerminalKey.numpad0 => 57399,
      TerminalKey.numpadDecimal => 57409,
      TerminalKey.numpadDivide => 57410,
      TerminalKey.numpadMultiply => 57411,
      TerminalKey.numpadSubtract => 57412,
      TerminalKey.numpadAdd => 57413,
      TerminalKey.numpadEnter => 57414,
      TerminalKey.numpadEqual => 57415,
      TerminalKey.numpadComma => 57416,
      _ => null,
    };
  }
}
