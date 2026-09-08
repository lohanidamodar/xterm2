import 'package:test/test.dart';
import 'package:xterm2/src/core/input/keytab/keytab.dart';
import 'package:xterm2/xterm.dart';

void main() {
  group('defaultInputHandler', () {
    test('supports numpad enter', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);
      terminal.keyInput(TerminalKey.numpadEnter);
      expect(output, ['\r']);
    });

    test('encodes modified enter keys distinctly', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.keyInput(TerminalKey.enter, shift: true);
      terminal.keyInput(TerminalKey.enter, alt: true);
      terminal.keyInput(TerminalKey.enter, shift: true, alt: true);
      terminal.keyInput(TerminalKey.enter, ctrl: true);
      terminal.keyInput(TerminalKey.enter, shift: true, ctrl: true);
      terminal.keyInput(TerminalKey.enter, alt: true, ctrl: true);
      terminal.keyInput(
        TerminalKey.enter,
        shift: true,
        alt: true,
        ctrl: true,
      );

      expect(output, [
        '\x1b[27;2;13~',
        '\x1b\r',
        '\x1b[27;4;13~',
        '\x1b[27;5;13~',
        '\x1b[27;6;13~',
        '\x1b[27;7;13~',
        '\x1b[27;8;13~',
      ]);
    });

    test('encodes modified escape keys distinctly', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.keyInput(TerminalKey.escape, shift: true);
      terminal.keyInput(TerminalKey.escape, alt: true);
      terminal.keyInput(TerminalKey.escape, shift: true, alt: true);
      terminal.keyInput(TerminalKey.escape, ctrl: true);
      terminal.keyInput(TerminalKey.escape, shift: true, ctrl: true);
      terminal.keyInput(TerminalKey.escape, alt: true, ctrl: true);
      terminal.keyInput(
        TerminalKey.escape,
        shift: true,
        alt: true,
        ctrl: true,
      );

      expect(output, [
        '\x1b[27;2;27~',
        '\x1b\x1b',
        '\x1b[27;4;27~',
        '\x1b[27;5;27~',
        '\x1b[27;6;27~',
        '\x1b[27;7;27~',
        '\x1b[27;8;27~',
      ]);
    });

    test('supports DEC application keypad with NumLock compatibility mode', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b=');
      terminal.keyInput(TerminalKey.numpad1);
      terminal.write('\x1b[?1035l');
      terminal.keyInput(TerminalKey.numpad1);
      terminal.keyInput(TerminalKey.numpadAdd);
      terminal.keyInput(TerminalKey.numpadEnter);
      terminal.keyInput(TerminalKey.numpadEqual);
      terminal.keyInput(TerminalKey.numpadComma);
      terminal.write('\x1b[?1035h');
      terminal.keyInput(TerminalKey.numpad1);

      expect(output, ['\x1bOq', '\x1bOk', '\x1bOM', '\x1bOX', '\x1bOl']);
    });

    test('honors ANSI keyboard action mode', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[2h');
      expect(terminal.keyInput(TerminalKey.keyA), isFalse);
      terminal.charInput(0x61, ctrl: true);
      terminal.textInput('text');
      terminal.paste('paste');
      terminal.write('\x1b[2l');
      expect(terminal.keyInput(TerminalKey.numpadEnter), isTrue);

      expect(output, ['\r']);
    });

    test('encodes alt backspace as escape delete', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.keyInput(TerminalKey.backspace, alt: true);
      terminal.keyInput(TerminalKey.backspace, alt: true, ctrl: true);

      expect(output, ['\x1b\x7f', '\x1b\b']);
    });

    test('supports xterm alt escape prefix modes', () {
      final output = <String>[];
      final terminal = Terminal(
        onOutput: output.add,
        platform: TerminalTargetPlatform.linux,
      );

      terminal.keyInput(TerminalKey.keyA, alt: true);
      terminal.write('\x1b[?1036l');
      terminal.keyInput(TerminalKey.keyA, alt: true);
      terminal.write('\x1b[?1036h');
      terminal.keyInput(TerminalKey.keyA, alt: true);

      expect(output, ['\x1ba', '\x1ba']);
    });

    test('supports macOS alt sends escape mode', () {
      final output = <String>[];
      final terminal = Terminal(
        onOutput: output.add,
        platform: TerminalTargetPlatform.macos,
      );

      terminal.keyInput(TerminalKey.keyA, alt: true);
      terminal.write('\x1b[?1039h');
      terminal.keyInput(TerminalKey.keyA, alt: true);
      terminal.write('\x1b[?1039l');
      terminal.keyInput(TerminalKey.keyA, alt: true);

      expect(output, ['\x1ba']);
    });

    test('supports shifted, punctuated, and non-ASCII Alt text', () {
      final output = <String>[];
      final terminal = Terminal(
        onOutput: output.add,
        platform: TerminalTargetPlatform.linux,
      );

      terminal.keyInput(
        TerminalKey.keyA,
        alt: true,
        shift: true,
        text: 'A',
      );
      terminal.keyInput(TerminalKey.slash, alt: true, shift: true, text: '?');
      terminal.keyInput(TerminalKey.none, alt: true, text: 'ф');

      expect(output, ['\x1bA', '\x1b?', 'ф']);
    });

    test('supports DEC backarrow key mode', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.keyInput(TerminalKey.backspace);
      terminal.write('\x1b[?67h');
      terminal.keyInput(TerminalKey.backspace);
      terminal.keyInput(TerminalKey.backspace, alt: true);
      terminal.keyInput(TerminalKey.backspace, ctrl: true);
      terminal.keyInput(TerminalKey.backspace, alt: true, ctrl: true);
      terminal.write('\x1b[?67l');
      terminal.keyInput(TerminalKey.backspace);

      expect(output, [
        '\x7f',
        '\b',
        '\x1b\b',
        '\x7f',
        '\x1b\x7f',
        '\x7f',
      ]);
    });

    test('keeps cursor keys normal in application keypad mode', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b=');
      terminal.keyInput(TerminalKey.arrowUp);

      expect(output, ['\x1b[A']);
    });

    test('uses application cursor keys in DECCKM mode', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[?1h');
      terminal.keyInput(TerminalKey.arrowUp);

      expect(output, ['\x1bOA']);
    });

    test('emits xterm-compatible extended function keys', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.keyInput(TerminalKey.f13);
      terminal.keyInput(TerminalKey.f16);
      terminal.keyInput(TerminalKey.f17);
      terminal.keyInput(TerminalKey.f24);

      expect(output, [
        '\x1b[1;2P',
        '\x1b[1;2S',
        '\x1b[15;2~',
        '\x1b[24;2~',
      ]);
    });

    test('encodes modified F1 through F4 as CSI sequences', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.keyInput(TerminalKey.f1, shift: true);
      terminal.keyInput(TerminalKey.f2, alt: true);
      terminal.keyInput(TerminalKey.f3, ctrl: true);
      terminal.keyInput(
        TerminalKey.f4,
        shift: true,
        alt: true,
        ctrl: true,
      );

      expect(output, [
        '\x1b[1;2P',
        '\x1b[1;3Q',
        '\x1b[1;5R',
        '\x1b[1;8S',
      ]);
    });

    test('leaves modified extended function keys to Kitty mode', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      expect(terminal.keyInput(TerminalKey.f13, shift: true), isFalse);
      terminal.write('\x1b[=1u');
      terminal.keyInput(TerminalKey.f13, shift: true);

      expect(output, ['\x1b[57376;2u']);
    });

    test('keeps legacy control encoding when Kitty mode is disabled', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.keyInput(TerminalKey.keyA, ctrl: true);
      terminal.keyInput(TerminalKey.keyC, ctrl: true, alt: true);

      expect(output, ['\x01', '\x1b\x03']);
    });

    test('supports legacy control punctuation chords', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.keyInput(TerminalKey.space, ctrl: true);
      terminal.keyInput(TerminalKey.bracketLeft, ctrl: true);
      terminal.keyInput(TerminalKey.backslash, ctrl: true);
      terminal.keyInput(TerminalKey.bracketRight, ctrl: true);
      terminal.keyInput(TerminalKey.digit6, ctrl: true, shift: true, text: '^');
      terminal.keyInput(TerminalKey.slash, ctrl: true);
      terminal.keyInput(TerminalKey.minus, ctrl: true, shift: true, text: '_');

      expect(output, ['\x00', '\x1b', '\x1c', '\x1d', '\x1e', '\x1f', '\x1f']);
    });

    test('supports legacy control number row chords', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.keyInput(TerminalKey.digit0, ctrl: true);
      terminal.keyInput(TerminalKey.digit1, ctrl: true);
      terminal.keyInput(TerminalKey.digit2, ctrl: true);
      terminal.keyInput(TerminalKey.digit3, ctrl: true);
      terminal.keyInput(TerminalKey.digit4, ctrl: true);
      terminal.keyInput(TerminalKey.digit5, ctrl: true);
      terminal.keyInput(TerminalKey.digit6, ctrl: true);
      terminal.keyInput(TerminalKey.digit7, ctrl: true);
      terminal.keyInput(TerminalKey.digit8, ctrl: true);
      terminal.keyInput(TerminalKey.digit9, ctrl: true);

      expect(
        output,
        ['0', '1', '\x00', '\x1b', '\x1c', '\x1d', '\x1e', '\x1f', '\x7f', '9'],
      );
    });

    test('supports shifted control punctuation aliases', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.keyInput(
        TerminalKey.digit2,
        ctrl: true,
        shift: true,
        text: '@',
      );
      terminal.keyInput(
        TerminalKey.slash,
        ctrl: true,
        shift: true,
        text: '?',
      );
      terminal.keyInput(
        TerminalKey.backquote,
        ctrl: true,
        shift: true,
        text: '~',
      );

      expect(output, ['\x00', '\x7f', '\x1e']);
    });

    test('preserves Ctrl+Shift letter chords with fixterms encoding', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.keyInput(TerminalKey.keyA, ctrl: true, shift: true);
      terminal.keyInput(
        TerminalKey.keyM,
        ctrl: true,
        shift: true,
        alt: true,
      );

      expect(output, ['\x1b[97;6u', '\x1b[109;8u']);
    });

    test('disambiguates modified textual keys in Kitty mode', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[=1u');
      terminal.keyInput(TerminalKey.keyA, ctrl: true);
      terminal.keyInput(TerminalKey.escape);

      expect(output, ['\x1b[97;5u', '\x1b[27u']);
    });

    test('reports all textual keys as Kitty escape sequences', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[=8u');
      terminal.keyInput(TerminalKey.keyA);
      terminal.keyInput(TerminalKey.digit0, shift: true);

      expect(output, ['\x1b[97u', '\x1b[48;2u']);
    });

    test('encodes escape when Kitty event reporting is enabled', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[=2u');
      terminal.keyInput(TerminalKey.escape);

      expect(output, ['\x1b[27u']);
    });

    test('disambiguates shifted control keys in Kitty mode', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[=1u');
      terminal.keyInput(TerminalKey.backspace, shift: true);
      terminal.keyInput(TerminalKey.enter, shift: true);
      terminal.keyInput(TerminalKey.tab, shift: true);

      expect(output, ['\x1b[127;2u', '\x1b[13;2u', '\x1b[9;2u']);
    });

    test('keeps unmodified Kitty control keys legacy', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[=1u');
      terminal.keyInput(TerminalKey.enter);
      terminal.keyInput(TerminalKey.backspace);
      terminal.keyInput(TerminalKey.tab);
      terminal.write('\x1b[?67h');
      terminal.keyInput(TerminalKey.backspace);

      expect(output, ['\r', '\x7f', '\t', '\x7f']);
    });

    test('keeps unmodified Kitty control key releases silent', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[=3u');
      terminal.keyInput(TerminalKey.enter, type: TerminalKeyEventType.release);
      terminal.keyInput(
        TerminalKey.backspace,
        type: TerminalKeyEventType.release,
      );
      terminal.keyInput(TerminalKey.tab, type: TerminalKeyEventType.release);

      expect(output, isEmpty);
    });

    test('reports unmodified Kitty control key releases in report-all mode',
        () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[=11u');
      terminal.keyInput(TerminalKey.enter, type: TerminalKeyEventType.release);
      terminal.keyInput(
        TerminalKey.backspace,
        type: TerminalKeyEventType.release,
      );
      terminal.keyInput(TerminalKey.tab, type: TerminalKeyEventType.release);

      expect(output, ['\x1b[13;1:3u', '\x1b[127;1:3u', '\x1b[9;1:3u']);
    });

    test('reports Kitty alternate key codes', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[=12u');
      terminal.keyInput(TerminalKey.keyA, shift: true);

      expect(output, ['\x1b[97:65;2u']);
    });

    test('uses Kitty functional and numpad key codes', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[=1u');
      terminal.keyInput(TerminalKey.f13);
      terminal.keyInput(TerminalKey.numpad0, alt: true);
      terminal.keyInput(TerminalKey.numpadComma);

      expect(output, ['\x1b[57376u', '\x1b[57399;3u', '\x1b[57416u']);
    });

    test('reports Kitty super and keyboard lock modifiers', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[=1u');
      terminal.keyInput(TerminalKey.keyA, superKey: true, text: 'a');
      terminal.keyInput(
        TerminalKey.f13,
        capsLock: true,
        numLock: true,
      );

      expect(output, ['\x1b[97;9u', '\x1b[57376;193u']);
    });

    test('reports Kitty repeat and release events', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[=3u');
      terminal.keyInput(
        TerminalKey.keyA,
        ctrl: true,
        type: TerminalKeyEventType.repeat,
      );
      terminal.keyInput(
        TerminalKey.keyA,
        type: TerminalKeyEventType.release,
      );
      terminal.keyInput(
        TerminalKey.arrowUp,
        type: TerminalKeyEventType.release,
      );

      expect(output, ['\x1b[97;5:2u', '\x1b[97;1:3u', '\x1b[1;1:3A']);
    });

    test('does not emit key releases outside Kitty event reporting', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      final handled = terminal.keyInput(
        TerminalKey.arrowUp,
        type: TerminalKeyEventType.release,
      );

      expect(handled, isFalse);
      expect(output, isEmpty);
    });

    test('reports associated text codepoints', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[=24u');
      terminal.keyInput(TerminalKey.keyA, text: 'a');
      terminal.keyInput(TerminalKey.none, text: 'é');

      expect(output, ['\x1b[97;;97u', '\x1b[233;;233u']);
    });

    test('omits Kitty associated text for modified keys', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[=24u');
      terminal.keyInput(TerminalKey.keyJ, ctrl: true, text: 'j');
      terminal.keyInput(TerminalKey.keyJ, alt: true, text: 'j');
      terminal.keyInput(TerminalKey.keyJ, shift: true, text: 'J');

      expect(output, ['\x1b[106;5u', '\x1b[106;3u', '\x1b[106;2;74u']);
    });

    test('omits Kitty control-character alternates', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[=12u');
      terminal.keyInput(TerminalKey.keyA, text: '\x01');

      expect(output, ['\x1b[97u']);
    });

    test('supports xterm modifyOtherKeys mode 2', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[>4;2m');
      terminal.keyInput(TerminalKey.keyH, ctrl: true, shift: true, text: 'H');
      terminal.keyInput(TerminalKey.digit8, alt: true, text: '8');
      terminal.write('\x1b[>4;0m');
      terminal.keyInput(TerminalKey.keyH, ctrl: true);

      expect(output, ['\x1b[27;6;72~', '\x1b[27;3;56~', '\x08']);
    });

    test('encodes every legacy arrow-key modifier combination', () {
      final output = <String>[];
      final terminal = Terminal(
        onOutput: output.add,
        platform: TerminalTargetPlatform.linux,
      );

      terminal.keyInput(TerminalKey.arrowUp, shift: true);
      terminal.keyInput(TerminalKey.arrowDown, alt: true);
      terminal.keyInput(TerminalKey.arrowRight, alt: true);
      terminal.keyInput(TerminalKey.arrowLeft, alt: true, ctrl: true);
      terminal.keyInput(
        TerminalKey.arrowRight,
        shift: true,
        alt: true,
        ctrl: true,
      );

      expect(output, [
        '\x1b[1;2A',
        '\x1b[1;3B',
        '\x1b[1;3C',
        '\x1b[1;7D',
        '\x1b[1;8C',
      ]);
    });

    test('preserves macOS Option word navigation', () {
      final output = <String>[];
      final terminal = Terminal(
        onOutput: output.add,
        platform: TerminalTargetPlatform.macos,
      );

      terminal.keyInput(TerminalKey.arrowRight, alt: true);
      terminal.keyInput(TerminalKey.arrowLeft, alt: true);
      terminal.keyInput(TerminalKey.arrowRight, alt: true, ctrl: true);
      terminal.keyInput(TerminalKey.arrowLeft, shift: true, alt: true);

      expect(output, [
        '\x1bf',
        '\x1bb',
        '\x1b[1;7C',
        '\x1b[1;4D',
      ]);
    });
  });

  group('KeytabInputHandler', () {
    test('can insert modifier code', () {
      final handler = KeytabInputHandler(
        Keytab.parse(r'key Home +AnyMod : "\E[1;*H"'),
      );

      final terminal = Terminal(inputHandler: handler);

      late String output;

      terminal.onOutput = (data) {
        output = data;
      };

      terminal.keyInput(TerminalKey.home, ctrl: true);

      expect(output, '\x1b[1;5H');

      terminal.keyInput(TerminalKey.home, shift: true);

      expect(output, '\x1b[1;2H');
    });

    test('does not emit keytab shortcut action names', () {
      final output = <String>[];
      final terminal = Terminal(
        inputHandler: KeytabInputHandler(
          Keytab.parse('key Home : scrollUpToTop'),
        ),
        onOutput: output.add,
      );

      expect(terminal.keyInput(TerminalKey.home), isFalse);
      expect(output, isEmpty);
    });
  });
  group('KittyKeyboardInputHandler functional keys', () {
    // Every expectation here is read off kitty's own encoder,
    // `kitty/key_encoding.c`'s `encode_function_key` and `serialize`, and off
    // the two tables in its `keyboard-protocol` document. The relevant lines:
    //
    // * "Functional key codes": LEFT `1 D`, RIGHT `1 C`, UP `1 A`, DOWN `1 B`,
    //   HOME `1 H`, END `1 F`, INSERT `2 ~`, DELETE `3 ~`, PAGE_UP `5 ~`,
    //   PAGE_DOWN `6 ~`, F1 `1 P`, F2 `1 Q`, F3 `13 ~`, F4 `1 S`, F5 `15 ~`
    //   ... F12 `24 ~`.
    // * "The escape codes above of the form ``CSI 1 letter`` will omit the
    //   ``1`` if there are no modifiers, since ``1`` is the default value."
    // * "The original version of this specification allowed F3 to be encoded
    //   as both CSI R and CSI ~. However, CSI R conflicts with the Cursor
    //   Position Report, so it was removed."
    // * "Some keys have an alternate representation when the terminal is in
    //   *cursor key mode* ... This form is used only in *cursor key mode* and
    //   only when no modifiers are present" — in the **Legacy** section, and
    //   `encode_function_key` reaches those `SS3` forms only when
    //   `legacy_mode`, which no enhancement leaves true.
    // * "If a modifier is *active* when the key event occurs, i.e. if the key
    //   is pressed or the lock (for caps lock/num lock) is enabled, the key
    //   event must have the bit for that modifier set", with
    //   `convert_glfw_mods` masking the locks off only when the flags are 0.

    /// The full set, in the order the spec tabulates it.
    const functional = <TerminalKey, String>{
      TerminalKey.arrowUp: 'A',
      TerminalKey.arrowDown: 'B',
      TerminalKey.arrowRight: 'C',
      TerminalKey.arrowLeft: 'D',
      TerminalKey.home: 'H',
      TerminalKey.end: 'F',
      TerminalKey.insert: '2~',
      TerminalKey.delete: '3~',
      TerminalKey.pageUp: '5~',
      TerminalKey.pageDown: '6~',
      TerminalKey.f1: 'P',
      TerminalKey.f2: 'Q',
      TerminalKey.f3: '13~',
      TerminalKey.f4: 'S',
      TerminalKey.f5: '15~',
      TerminalKey.f6: '17~',
      TerminalKey.f7: '18~',
      TerminalKey.f8: '19~',
      TerminalKey.f9: '20~',
      TerminalKey.f10: '21~',
      TerminalKey.f11: '23~',
      TerminalKey.f12: '24~',
    };

    List<String> press(String setup, Iterable<TerminalKey> keys) {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);
      if (setup.isNotEmpty) terminal.write(setup);
      for (final key in keys) {
        terminal.keyInput(key);
      }
      return output;
    }

    test('sends what kitty sends for a functional key press under flags 7', () {
      // `CSI = 7 u` is what Codex asks for: disambiguate | report event types
      // | report alternate keys.
      expect(
        press('\x1b[=7u', functional.keys),
        functional.values.map((code) => '\x1b[$code'),
      );
    });

    test('ignores cursor key mode once a program enables the protocol', () {
      const cursorKeys = <TerminalKey>[
        TerminalKey.arrowUp,
        TerminalKey.arrowDown,
        TerminalKey.arrowRight,
        TerminalKey.arrowLeft,
        TerminalKey.home,
        TerminalKey.end,
      ];

      // DECCKM on, then the flags. A WSL pane arrives in exactly this state:
      // zsh's line editor sets application cursor keys, and the agent that
      // starts under it asks for the protocol without clearing them.
      expect(
        press('\x1b[?1h\x1b[=7u', cursorKeys),
        ['\x1b[A', '\x1b[B', '\x1b[C', '\x1b[D', '\x1b[H', '\x1b[F'],
      );
      // ... and each of the three enhancements that ends `legacy_mode` does
      // it on its own.
      for (final flags in <String>['\x1b[=1u', '\x1b[=2u', '\x1b[=8u']) {
        expect(
          press('\x1b[?1h$flags', [TerminalKey.end]),
          ['\x1b[F'],
          reason: 'cursor key mode must not survive $flags',
        );
      }
    });

    test('reports lock and super modifiers a keytab cannot express', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add)..write('\x1b[=7u');

      terminal.keyInput(TerminalKey.end, numLock: true);
      terminal.keyInput(TerminalKey.end, capsLock: true);
      terminal.keyInput(TerminalKey.arrowRight, superKey: true);
      terminal.keyInput(TerminalKey.f5, capsLock: true, numLock: true);
      terminal.keyInput(TerminalKey.arrowRight, ctrl: true);
      terminal.keyInput(TerminalKey.f3, shift: true);

      expect(output, [
        '\x1b[1;129F',
        '\x1b[1;65F',
        '\x1b[1;9C',
        '\x1b[15;193~',
        '\x1b[1;5C',
        '\x1b[13;2~',
      ]);
    });

    test('reports functional repeats and releases with event types', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add)..write('\x1b[=7u');

      terminal.keyInput(TerminalKey.end, type: TerminalKeyEventType.repeat);
      terminal.keyInput(TerminalKey.end, type: TerminalKeyEventType.release);
      terminal.keyInput(TerminalKey.f5, type: TerminalKeyEventType.release);
      terminal.keyInput(
        TerminalKey.arrowRight,
        ctrl: true,
        type: TerminalKeyEventType.release,
      );

      expect(output, [
        '\x1b[1;1:2F',
        '\x1b[1;1:3F',
        '\x1b[15;1:3~',
        '\x1b[1;5:3C',
      ]);
    });

    test('stays silent on a release the program did not ask for', () {
      // `encode_key`: "if (!ev->report_all_event_types && ev->action ==
      // RELEASE) return 0;" — and a repeat is still a keystroke.
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add)..write('\x1b[=1u');

      expect(
        terminal.keyInput(TerminalKey.end, type: TerminalKeyEventType.release),
        isFalse,
      );
      expect(
        terminal.keyInput(TerminalKey.f13, type: TerminalKeyEventType.release),
        isFalse,
      );
      expect(
        terminal.keyInput(
          TerminalKey.numpad0,
          type: TerminalKeyEventType.release,
        ),
        isFalse,
      );
      expect(output, isEmpty);

      terminal.keyInput(TerminalKey.end, type: TerminalKeyEventType.repeat);
      expect(output, ['\x1b[F']);
    });

    test('leaves every legacy functional sequence byte for byte alone', () {
      // The ordinary shell case, which no part of this may move. These are the
      // bytes the keytab has always produced, measured before the change.
      expect(press('', functional.keys), [
        '\x1b[A',
        '\x1b[B',
        '\x1b[C',
        '\x1b[D',
        '\x1b[H',
        '\x1b[F',
        '\x1b[2~',
        '\x1b[3~',
        '\x1b[5~',
        '\x1b[6~',
        '\x1bOP',
        '\x1bOQ',
        '\x1bOR',
        '\x1bOS',
        '\x1b[15~',
        '\x1b[17~',
        '\x1b[18~',
        '\x1b[19~',
        '\x1b[20~',
        '\x1b[21~',
        '\x1b[23~',
        '\x1b[24~',
      ]);

      // Including the `SS3` forms of cursor key mode, which belong to a pane
      // that never enabled the protocol.
      expect(press('\x1b[?1h', functional.keys), [
        '\x1bOA',
        '\x1bOB',
        '\x1bOC',
        '\x1bOD',
        '\x1bOH',
        '\x1bOF',
        '\x1b[2~',
        '\x1b[3~',
        '\x1b[5~',
        '\x1b[6~',
        '\x1bOP',
        '\x1bOQ',
        '\x1bOR',
        '\x1bOS',
        '\x1b[15~',
        '\x1b[17~',
        '\x1b[18~',
        '\x1b[19~',
        '\x1b[20~',
        '\x1b[21~',
        '\x1b[23~',
        '\x1b[24~',
      ]);

      // ... and the modified forms, whose modifier parameter is xterm's.
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);
      terminal.keyInput(TerminalKey.end, ctrl: true);
      terminal.keyInput(TerminalKey.end, shift: true);
      terminal.keyInput(TerminalKey.end, alt: true);
      terminal.keyInput(TerminalKey.arrowRight, ctrl: true);
      terminal.keyInput(TerminalKey.f3, shift: true);
      terminal.keyInput(TerminalKey.f5, ctrl: true);
      terminal.keyInput(TerminalKey.end, numLock: true, capsLock: true);
      terminal.keyInput(TerminalKey.arrowRight, superKey: true);

      expect(output, [
        '\x1b[1;5F',
        '\x1b[1;2F',
        '\x1b[1;3F',
        '\x1b[1;5C',
        '\x1b[1;2R',
        '\x1b[15;5~',
        '\x1b[F',
        '\x1b[C',
      ]);
    });
  });
}
