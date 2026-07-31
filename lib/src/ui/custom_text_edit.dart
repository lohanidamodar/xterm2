import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CustomTextEdit extends StatefulWidget {
  CustomTextEdit({
    super.key,
    required this.child,
    required this.onInsert,
    required this.onDelete,
    required this.onComposing,
    required this.onAction,
    required this.onKeyEvent,
    required this.focusNode,
    this.autofocus = false,
    this.readOnly = false,
    // this.initEditingState = TextEditingValue.empty,
    int? viewId,
    this.inputType = TextInputType.text,
    this.inputAction = TextInputAction.newline,
    this.keyboardAppearance = Brightness.light,
    this.deleteDetection = false,
  }) : viewId = viewId ?? PlatformDispatcher.instance.implicitView?.viewId {
    if (this.viewId == null) {
      throw Exception('Cannot open input connection without a valid viewId.');
    }
  }

  final Widget child;

  final void Function(String) onInsert;

  final void Function() onDelete;

  final void Function(String?) onComposing;

  final void Function(TextInputAction) onAction;

  final KeyEventResult Function(FocusNode, KeyEvent) onKeyEvent;

  final FocusNode focusNode;

  final bool autofocus;

  final bool readOnly;

  final TextInputType inputType;

  final TextInputAction inputAction;

  final Brightness keyboardAppearance;

  final bool deleteDetection;

  final int? viewId;

  @override
  CustomTextEditState createState() => CustomTextEditState();
}

class CustomTextEditState extends State<CustomTextEdit> with TextInputClient {
  TextInputConnection? _connection;
  final Set<PhysicalKeyboardKey> _composingPhysicalKeys = {};
  KeyEvent? _deferredTextInputKeyEvent;
  KeyEvent? _pendingComposingKeyEvent;
  bool _hasImplicitKoreanComposition = false;
  int _implicitKoreanCommittedLength = 0;
  bool _isDisposing = false;

  @override
  void initState() {
    widget.focusNode.addListener(_onFocusChange);
    super.initState();
  }

  @override
  void didUpdateWidget(CustomTextEdit oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
    }

    if (!_shouldCreateInputConnection) {
      _closeInputConnectionIfNeeded();
    } else {
      if (oldWidget.readOnly && widget.focusNode.hasFocus) {
        _openInputConnection();
      }
    }
  }

  @override
  void dispose() {
    _isDisposing = true;
    widget.focusNode.removeListener(_onFocusChange);
    _closeInputConnectionIfNeeded();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: _onKeyEvent,
      child: widget.child,
    );
  }

  bool get hasInputConnection {
    final connection = _connection;
    return connection != null && connection.attached;
  }

  void requestKeyboard() {
    if (widget.focusNode.hasFocus) {
      _openInputConnection();
    } else {
      widget.focusNode.requestFocus();
    }
  }

  void closeKeyboard() {
    _closeInputConnectionIfNeeded();
  }

  void setEditingState(TextEditingValue value) {
    _currentEditingState = value;
    _connection?.setEditingState(value);
  }

  void setEditableRect(Rect rect, Rect caretRect) {
    if (!hasInputConnection) {
      return;
    }

    _connection?.setEditableSizeAndTransform(
      rect.size,
      Matrix4.translationValues(0, 0, 0),
    );

    _connection?.setCaretRect(caretRect);
  }

  void _onFocusChange() {
    _openOrCloseInputConnectionIfNeeded();
  }

  KeyEventResult _onKeyEvent(FocusNode focusNode, KeyEvent event) {
    if (event is KeyUpEvent) {
      final wasComposingKey = _composingPhysicalKeys.remove(
        event.physicalKey,
      );
      if (_deferredTextInputKeyEvent?.physicalKey == event.physicalKey) {
        _deferredTextInputKeyEvent = null;
      }
      if (_pendingComposingKeyEvent?.physicalKey == event.physicalKey) {
        _pendingComposingKeyEvent = null;
      }
      if (wasComposingKey) {
        return KeyEventResult.skipRemainingHandlers;
      }
    }

    if (_hasImplicitKoreanComposition &&
        (event is KeyDownEvent || event is KeyRepeatEvent)) {
      if (event.logicalKey == LogicalKeyboardKey.backspace &&
          _shouldDeleteImplicitKoreanCompositionLocally()) {
        _composingPhysicalKeys.add(event.physicalKey);
        _deleteImplicitKoreanComposition();
        return KeyEventResult.handled;
      }
      if (_continuesImplicitKoreanComposition(event)) {
        _composingPhysicalKeys.add(event.physicalKey);
        return KeyEventResult.skipRemainingHandlers;
      }
      _commitImplicitKoreanComposition();
    }

    if (_currentEditingState.composing.isCollapsed) {
      final result = widget.onKeyEvent(focusNode, event);
      if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
          result == KeyEventResult.skipRemainingHandlers) {
        _deferredTextInputKeyEvent = event;
      }
      return result;
    }

    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _composingPhysicalKeys.add(event.physicalKey);
      _pendingComposingKeyEvent = event;
    }
    return KeyEventResult.skipRemainingHandlers;
  }

  void _openOrCloseInputConnectionIfNeeded() {
    if (widget.focusNode.hasFocus && widget.focusNode.consumeKeyboardToken()) {
      _openInputConnection();
    } else if (!widget.focusNode.hasFocus) {
      _closeInputConnectionIfNeeded();
    }
  }

  bool get _shouldCreateInputConnection => kIsWeb || !widget.readOnly;

  void _openInputConnection() {
    if (!_shouldCreateInputConnection) {
      return;
    }

    final existingConnection = _connection;
    if (existingConnection != null && existingConnection.attached) {
      existingConnection.show();
      return;
    }

    final config = TextInputConfiguration(
      viewId: widget.viewId,
      inputType: widget.inputType,
      inputAction: widget.inputAction,
      keyboardAppearance: widget.keyboardAppearance,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
    );

    final connection = TextInput.attach(this, config);
    _connection = connection;
    _currentEditingState = _initEditingState;
    connection.show();
    connection.setEditingState(_currentEditingState);
  }

  void _closeInputConnectionIfNeeded() {
    if (!_isDisposing) {
      _commitImplicitKoreanComposition();
    }
    final connection = _connection;
    _connection = null;
    _composingPhysicalKeys.clear();
    _deferredTextInputKeyEvent = null;
    _pendingComposingKeyEvent = null;
    _hasImplicitKoreanComposition = false;
    _implicitKoreanCommittedLength = 0;
    _currentEditingState = _initEditingState;
    if (!_isDisposing) {
      widget.onComposing(null);
    }
    if (connection == null || !connection.attached) return;

    connection.close();
  }

  TextEditingValue get _initEditingState => widget.deleteDetection
      ? const TextEditingValue(
          text: '  ',
          selection: TextSelection.collapsed(offset: 2),
        )
      : const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        );

  late var _currentEditingState = _initEditingState.copyWith();

  @override
  TextEditingValue? get currentTextEditingValue {
    return _currentEditingState;
  }

  @override
  AutofillScope? get currentAutofillScope {
    return null;
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    if (!hasInputConnection) return;

    final previousEditingState = _currentEditingState;
    final wasComposing = !previousEditingState.composing.isCollapsed;
    _currentEditingState = value;

    if (_hasImplicitKoreanComposition) {
      _updateImplicitKoreanComposition(previousEditingState);
      return;
    }

    if (_startsImplicitKoreanComposition(previousEditingState, value)) {
      _hasImplicitKoreanComposition = true;
      _implicitKoreanCommittedLength = 0;
      final deferredKeyEvent = _deferredTextInputKeyEvent;
      if (deferredKeyEvent != null) {
        _composingPhysicalKeys.add(deferredKeyEvent.physicalKey);
        _deferredTextInputKeyEvent = null;
      }
      widget.onComposing(_editingText(value));
      return;
    }

    // Get input after composing is done
    if (!_currentEditingState.composing.isCollapsed) {
      final deferredKeyEvent = _deferredTextInputKeyEvent;
      if (deferredKeyEvent != null) {
        _composingPhysicalKeys.add(deferredKeyEvent.physicalKey);
        _deferredTextInputKeyEvent = null;
      }
      _pendingComposingKeyEvent = null;
      final text = _currentEditingState.text;
      final composingText = _currentEditingState.composing.textInside(text);
      widget.onComposing(composingText);
      return;
    }

    widget.onComposing(null);

    final initialState = _initEditingState;
    final committedText = _currentEditingState.text;
    final composingKeyEvent = _pendingComposingKeyEvent;
    _pendingComposingKeyEvent = null;
    _currentEditingState = initialState;
    _connection?.setEditingState(initialState);

    if (committedText.length < initialState.text.length) {
      widget.onDelete();
      return;
    }

    final textDelta = switch (committedText.startsWith(initialState.text)) {
      true => committedText.substring(initialState.text.length),
      false => committedText,
    };
    if (textDelta.isEmpty) return;

    widget.onInsert(textDelta);
    if (wasComposing &&
        composingKeyEvent != null &&
        _shouldReplayComposingCommitKey(composingKeyEvent)) {
      _composingPhysicalKeys.remove(composingKeyEvent.physicalKey);
      widget.onKeyEvent(widget.focusNode, composingKeyEvent);
    }
  }

  bool _shouldReplayComposingCommitKey(KeyEvent event) {
    final logicalKey = event.logicalKey;
    if (logicalKey == LogicalKeyboardKey.arrowUp) return true;
    if (logicalKey == LogicalKeyboardKey.arrowRight) return true;
    if (logicalKey == LogicalKeyboardKey.arrowDown) return true;
    if (logicalKey != LogicalKeyboardKey.arrowLeft) return false;

    final keyboard = HardwareKeyboard.instance;
    return keyboard.isShiftPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed;
  }

  bool _startsImplicitKoreanComposition(
    TextEditingValue previous,
    TextEditingValue value,
  ) {
    if (!previous.composing.isCollapsed || !value.composing.isCollapsed) {
      return false;
    }
    if (previous != _initEditingState) return false;

    final text = _editingText(value);
    final runes = text.runes;
    return runes.length == 1 && _isHangulCompatibilityJamo(runes.first);
  }

  void _updateImplicitKoreanComposition(TextEditingValue previousState) {
    final text = _editingText(_currentEditingState);
    if (text.isEmpty) {
      _clearImplicitKoreanComposition();
      return;
    }
    if (text.runes.every(_isHangulCompositionCharacter)) {
      final previousText = _editingText(previousState);
      if (text.length > previousText.length &&
          text.startsWith(previousText) &&
          previousText.isNotEmpty) {
        final stableLength = _lastRuneStart(text);
        if (stableLength > _implicitKoreanCommittedLength) {
          widget.onInsert(
            text.substring(_implicitKoreanCommittedLength, stableLength),
          );
          _implicitKoreanCommittedLength = stableLength;
        }
      }
      widget.onComposing(text.substring(_implicitKoreanCommittedLength));
      return;
    }
    _commitImplicitKoreanComposition();
  }

  void _deleteImplicitKoreanComposition() {
    final text = _editingText(_currentEditingState);
    final composingText = text.substring(_implicitKoreanCommittedLength);
    if (composingText.isEmpty) {
      _clearImplicitKoreanComposition();
      return;
    }

    final remainingComposingText = composingText.substring(
      0,
      _lastRuneStart(composingText),
    );
    if (remainingComposingText.isEmpty) {
      _clearImplicitKoreanComposition();
      return;
    }

    final committedText = text.substring(0, _implicitKoreanCommittedLength);
    _setImplicitEditingText('$committedText$remainingComposingText');
    widget.onComposing(remainingComposingText);
  }

  bool _shouldDeleteImplicitKoreanCompositionLocally() {
    final text = _editingText(_currentEditingState);
    final composingText = text.substring(_implicitKoreanCommittedLength);
    return composingText.runes.every(
      (codePoint) => codePoint < 0xac00 || codePoint > 0xd7a3,
    );
  }

  void _clearImplicitKoreanComposition() {
    _hasImplicitKoreanComposition = false;
    _implicitKoreanCommittedLength = 0;
    _currentEditingState = _initEditingState;
    _connection?.setEditingState(_currentEditingState);
    widget.onComposing(null);
  }

  void _setImplicitEditingText(String text) {
    final fullText = '${_initEditingState.text}$text';
    _currentEditingState = TextEditingValue(
      text: fullText,
      selection: TextSelection.collapsed(offset: fullText.length),
    );
    _connection?.setEditingState(_currentEditingState);
  }

  int _lastRuneStart(String text) {
    final lastRune = String.fromCharCode(text.runes.last);
    return text.length - lastRune.length;
  }

  void _commitImplicitKoreanComposition() {
    if (!_hasImplicitKoreanComposition) return;

    final text = _editingText(_currentEditingState).substring(
      _implicitKoreanCommittedLength,
    );
    _hasImplicitKoreanComposition = false;
    _implicitKoreanCommittedLength = 0;
    _currentEditingState = _initEditingState;
    _connection?.setEditingState(_currentEditingState);
    widget.onComposing(null);
    if (text.isNotEmpty) {
      widget.onInsert(text);
    }
  }

  String _editingText(TextEditingValue value) {
    final initialText = _initEditingState.text;
    if (!value.text.startsWith(initialText)) return value.text;
    return value.text.substring(initialText.length);
  }

  bool _continuesImplicitKoreanComposition(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed) return false;
    if (keyboard.isAltPressed) return false;
    if (keyboard.isMetaPressed) return false;

    final logicalKey = event.logicalKey;
    if (logicalKey == LogicalKeyboardKey.backspace) return true;
    if (logicalKey == LogicalKeyboardKey.delete) return true;
    if (logicalKey == LogicalKeyboardKey.shiftLeft) return true;
    if (logicalKey == LogicalKeyboardKey.shiftRight) return true;
    if (logicalKey == LogicalKeyboardKey.capsLock) return true;

    final character = event.character;
    if (character == null || character.isEmpty) return false;
    return character.runes.every(
      (codePoint) => codePoint >= 0x20 && codePoint != 0x7f,
    );
  }

  bool _isHangulCompositionCharacter(int codePoint) {
    if (_isHangulCompatibilityJamo(codePoint)) return true;
    if (codePoint >= 0x1100 && codePoint <= 0x11ff) return true;
    if (codePoint >= 0xa960 && codePoint <= 0xa97f) return true;
    if (codePoint >= 0xac00 && codePoint <= 0xd7a3) return true;
    return codePoint >= 0xd7b0 && codePoint <= 0xd7ff;
  }

  bool _isHangulCompatibilityJamo(int codePoint) {
    return codePoint >= 0x3130 && codePoint <= 0x318f;
  }

  @override
  void performAction(TextInputAction action) {
    // print('performAction $action');
    _commitImplicitKoreanComposition();
    widget.onAction(action);
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    // print('updateFloatingCursor $point');
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {
    // print('showAutocorrectionPromptRect');
  }

  @override
  void connectionClosed() {
    final pendingKoreanText = switch (_hasImplicitKoreanComposition) {
      true => _editingText(
          _currentEditingState,
        ).substring(_implicitKoreanCommittedLength),
      false => '',
    };
    _connection = null;
    _composingPhysicalKeys.clear();
    _deferredTextInputKeyEvent = null;
    _pendingComposingKeyEvent = null;
    _hasImplicitKoreanComposition = false;
    _implicitKoreanCommittedLength = 0;
    _currentEditingState = _initEditingState;
    if (!_isDisposing) {
      widget.onComposing(null);
      if (pendingKoreanText.isNotEmpty) {
        widget.onInsert(pendingKoreanText);
      }
    }
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {
    // print('performPrivateCommand $action');
  }

  @override
  void insertTextPlaceholder(Size size) {
    // print('insertTextPlaceholder');
  }

  @override
  void removeTextPlaceholder() {
    // print('removeTextPlaceholder');
  }

  @override
  void showToolbar() {
    // print('showToolbar');
  }
}
