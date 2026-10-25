import 'package:html/dom.dart';
import 'package:kover/utils/extensions/document_fragment.dart';
import 'package:kover/utils/html_constants.dart';

abstract class ReflowEngine {
  /// The current buffer element that is being built.
  Element get buffer;

  /// Adds the next node from the source tree to the buffer.
  /// Returns true when a node was added, false if there are no more nodes to add.
  ///
  /// [fill] is the measured height of the buffer divided by the available
  /// height, when the driver knows it.
  bool addNext({double? fill});

  /// Marks the current buffer as overflowing. [fill] is as in [addNext].
  bool overflow({double? fill});

  /// Commits the current buffer and returns a new buffer for further additions.
  Element commitSplit();
}

/// Exponential + binary search based reflow engine. Each tree level probes
/// exponential prefixes (1, 2, 4, ...) until the content overflows, then binary
/// searches between the last known fit and that overflow. When the boundary
/// unit is found, the engine descends one level and repeats, until the unit is
/// unsplittable (same end condition as the previous linear cursor).
///
/// When the driver reports how full each measured buffer is, probes are aimed
/// at the boundary instead: the next probe is the prefix whose text length
/// should just fill the page, estimated from the measured fills. A level falls
/// back to galloping and bisection when its estimates keep landing on the
/// same side of the boundary. Either way each level ends on the same boundary,
/// so the pages are the same; aiming only takes fewer measures.
class ExponentialBinaryReflowEngine implements ReflowEngine {
  static const Set<String> _leafTags = {'img', 'svg'};
  static final _wordsReg = RegExp(r'(?=\s)');

  /// Measures fuller than this estimate the text length of a page.
  static const double _minEstimateFill = 0.2;

  final Element _root;
  final Element _buffer;
  final List<_Frame> _frames = [];

  /// Estimated text length of a full page, from the last measured fill.
  double? _pageChars;

  ExponentialBinaryReflowEngine({required Element root})
    : _root = root.clone(true),
      _buffer = root.clone(false) {
    _frames.add(_Frame(target: _buffer, pending: List.of(_root.nodes)));
  }

  @override
  Element get buffer => _buffer;

  @override
  bool addNext({double? fill}) {
    if (_frames.isEmpty) return false;

    final frame = _frames.last;

    // Level exhausted: pop and continue the parent level.
    if (frame.pending.isEmpty) {
      _frames.removeLast();
      return addNext(fill: fill);
    }

    // The current probe fits.
    final measure = _measure(fill);
    frame.lo = frame.p;
    frame.fit(measure);

    if (frame.p == frame.pending.length) {
      // The whole level fits: pop. The parent resumes past the straddler
      // slot, which permanently shows the child shell from now on.
      _frames.removeLast();
      if (_frames.isEmpty) return false;

      final parent = _frames.last;
      final slot = parent.splitAt!;
      parent.pending[slot] = frame.target;
      parent.pendingChanged();
      parent.splitAt = null;
      parent.lo = slot + 1;
      parent.fit(measure);
      if (parent.hi <= parent.lo) {
        parent.exponential = true;
      }
      _advance(parent);
      return true;
    }

    _advance(frame);
    return true;
  }

  /// Mirrors the next probe of [frame]: aimed at the boundary when it can be
  /// estimated, else exponential while no overflow bound is known, otherwise
  /// binary searching the bounded range.
  void _advance(_Frame frame) {
    // The probe past the last fit is known to overflow: descend into a
    // splittable overflower without measuring it again.
    if (!frame.exponential &&
        frame.hi == frame.lo + 1 &&
        frame.hiMeasure != null &&
        _isSplittable(frame.pending[frame.lo])) {
      frame.p = frame.hi;
      _rebuild(frame);
      _descend(frame);
      return;
    }

    final aimed = _aim(frame);
    if (aimed != null) {
      frame.p = aimed;
    } else if (frame.exponential) {
      final grown = frame.lo < 1 ? 1 : frame.lo * 2;
      frame.p = grown < frame.pending.length ? grown : frame.pending.length;
    } else {
      // The range is bounded by a probe that overflowed: binary-search it.
      // When the range collapsed (hi == lo + 1) this re-appends the known
      // overflower so the driver reports overflow and the boundary handling
      // kicks in.
      frame.p = frame.lo + ((frame.hi - frame.lo + 1) >> 1);
    }
    _rebuild(frame);
  }

  @override
  bool overflow({double? fill}) {
    if (_frames.isEmpty) return false;

    final frame = _frames.last;
    if (frame.p == 0) return false;

    final measure = _measure(fill);
    frame.hi = frame.p;
    frame.overflow(measure);
    // Once a probe overflows, stop exponential probing and binary-search the range.
    frame.exponential = false;

    // Range not collapsed: shrink the probe, aimed or to the midpoint.
    if (frame.hi - frame.lo > 1) {
      frame.p = _aim(frame) ?? (frame.lo + frame.hi) >> 1;
      _rebuild(frame);
      return true;
    }

    // Boundary found: pending[lo] is the overflower. Descend.
    if (!_isSplittable(frame.pending[frame.lo])) {
      _acceptUnsplittable(frame);
      return false;
    }
    _descend(frame);
    return true;
  }

  /// Whether the overflowing [unit] can be split into smaller units.
  bool _isSplittable(Node unit) {
    if (unit is Text) return _textSegments(unit.text) != null;

    return unit is Element &&
        !_leafTags.contains(unit.localName) &&
        unit.nodes.isNotEmpty &&
        !unit.attributes.containsKey(HtmlConstants.textIndentSpanAttribute);
  }

  /// Descends into the splittable overflower pending[lo] of [frame], which
  /// is mirrored last, and mirrors the first probe inside it.
  void _descend(_Frame frame) {
    final unit = frame.pending[frame.lo];

    if (unit is Text) {
      final segments = _textSegments(unit.text)!;
      frame.pending
        ..removeAt(frame.lo)
        ..insertAll(frame.lo, segments.map(Text.new));
      frame.pendingChanged();
      // The bounds still hold: the first lo units fit, all of them overflow.
      frame.hi = frame.lo + segments.length;
      frame.streak = 0;
      frame.p = _aim(frame) ?? frame.lo;
      _rebuild(frame);
      return;
    }

    // Descend one level: swap the tree node for an empty shell clone. The
    // unit itself stays untouched in pending until the child level pops.
    final shell = (unit as Element).clone(false);
    frame.target.nodes.last.replaceWith(shell);
    frame.splitAt = frame.lo;
    final child = _Frame(target: shell, pending: List.of(unit.nodes));
    _frames.add(child);

    // The empty shell measures like the parent's last fit, the full one
    // like its overflow: probe between them without measuring the shell.
    if (frame.loMeasure != null && frame.hiMeasure != null) {
      child
        ..loMeasure = frame.loMeasure
        ..hiMeasure = frame.hiMeasure
        ..exponential = false;
      _advance(child);
    }
  }

  @override
  Element commitSplit() {
    final frame = _frames.last;

    // Backtrack the overflower so it resumes on the next page. An accepted
    // unsplittable overflower (p == lo) stays on the committed page.
    if (frame.p > frame.lo && frame.target.nodes.isNotEmpty) {
      frame.target.nodes.removeLast();
    }

    frame.pending.removeRange(0, frame.lo);

    // Drop whitespace at the start of the next page.
    if (frame.pending.isNotEmpty && frame.pending.first is Text) {
      final first = frame.pending.first as Text;
      first.data = first.data.trimLeft();
    }

    // Ancestors committed everything before the straddler unit. The unit
    // itself stays (hollow) so the child shell swap keeps its slot.
    for (final f in _frames.take(_frames.length - 1)) {
      f.pending.removeRange(0, f.splitAt!);
      f.splitAt = 0;
    }

    final result = _buffer.clone(true);

    // Remove empty paragraph shells.
    result
        .querySelectorAll('p')
        .where((p) => !p.hasVisibleNodes)
        .forEach((p) => p.remove());

    // Mark a trailing split paragraph so the renderer can omit its bottom
    // margin: the split halves should read as one paragraph.
    final hasSplitParagraph = _frames.any(
      (f) => f.target.localName == 'p' && f.target.hasVisibleNodes,
    );
    if (hasSplitParagraph) {
      final trailing = result.localName == 'p'
          ? result
          : result.querySelectorAll('p').lastOrNull;
      trailing?.attributes[HtmlConstants.splitParagraphAttribute] = '';
    }

    // Reconstruct a clear tree up to the deepest target.
    Element? parent;
    for (final f in _frames) {
      f.target.nodes.clear();
      if (parent != null) parent.append(f.target);
      parent = f.target;
    }

    // The fresh page re-measures everything: reset the bounds.
    for (final f in _frames) {
      f.reset();
    }

    // With a page estimate, the first probe of the next page is aimed too.
    final deepest = _frames.last;
    final aimed = _aim(deepest);
    if (aimed != null) {
      deepest.p = aimed;
      _rebuild(deepest);
    }

    return result;
  }

  /// The text length of the buffer with the [fill] it measured, which also
  /// refreshes the page estimate. Null without a fill.
  _Measure? _measure(double? fill) {
    if (fill == null) return null;

    final chars = _buffer.text.length;
    if (fill >= _minEstimateFill && chars > 0) {
      _pageChars = chars / fill;
    }
    return (chars: chars, fill: fill);
  }

  /// The next probe of [frame] aimed at the boundary, or null when it can't
  /// be estimated and the frame should gallop or bisect instead.
  ///
  /// Between a measured fit and a measured overflow the target text length
  /// is interpolated at a fill of 1; with no overflow bound yet it is the
  /// page estimate. The probe is the longest prefix within the target,
  /// strictly inside the known bounds.
  int? _aim(_Frame frame) {
    final upper = frame.exponential ? frame.pending.length : frame.hi - 1;
    if (upper <= frame.lo) return null;
    // Estimates landing twice in a row on the same side bisect instead.
    if (!frame.exponential && frame.streak >= 2) return null;

    final lo = frame.loMeasure;
    final hi = frame.hiMeasure;
    final double target;
    if (!frame.exponential && lo != null && hi != null && hi.fill > lo.fill) {
      target =
          lo.chars +
          (1 - lo.fill) * (hi.chars - lo.chars) / (hi.fill - lo.fill);
    } else if (_pageChars != null) {
      target = _pageChars!;
    } else {
      return null;
    }

    // Text of the buffer outside the units this frame mirrors.
    final outside = _buffer.text.length - frame.target.text.length;
    final within = target - outside;

    final cum = frame.cum;
    var low = 0;
    var high = cum.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (cum[mid] <= within) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }

    // Without an overflow bound, grow by at least the doubling minimum while
    // probes keep fitting.
    final least = frame.lo + (frame.exponential ? frame.minStep : 1);
    return low.clamp(least < upper ? least : upper, upper);
  }

  /// Marks an unsplittable overflower as accepted when the current page
  /// holds nothing else: it gets the page to itself (visually overflowing)
  /// and [commitSplit] consumes it, guaranteeing progress.
  void _acceptUnsplittable(_Frame frame) {
    if (frame.lo == 0 && _frames.every((f) => (f.splitAt ?? 0) == 0)) {
      frame.lo = frame.p;
    }
  }

  /// Splits [text] into words. The whitespace leads the following word, so a
  /// page-ending word is measured without its trailing whitespace while no
  /// whitespace is lost. Returns null when the text is a single word.
  List<String>? _textSegments(String text) {
    final words = text
        .split(_wordsReg)
        .where((word) => word.isNotEmpty)
        .toList();

    return words.length > 1 ? words : null;
  }

  /// Mirrors the first [_Frame.p] units of [frame] into its target.
  void _rebuild(_Frame frame) {
    frame.target.nodes
      ..clear()
      ..addAll(frame.pending.take(frame.p));
  }
}

/// The text length of a measured buffer and how full it was.
typedef _Measure = ({int chars, double fill});

/// One binary search level: the units of a single target element.
class _Frame {
  _Frame({required this.target, required this.pending}) : hi = pending.length;

  /// The element in the buffer tree units are mirrored into.
  final Element target;

  /// The units of this level; the first [p] are mirrored into [target].
  final List<Node> pending;

  /// Binary search pivot point. Matches units currently mirrored into [target].
  int p = 0;

  /// Binary search lower bound. Matches units known to fit into [target].
  int lo = 0;

  /// Binary search upper bound. Matches units known to overflow [target].
  int hi;

  /// Whether the search is still in the exponential probing phase
  /// or has an overflow bound and can halve the range.
  bool exponential = true;

  /// Index of the straddler unit a child frame descended into, if any.
  int? splitAt;

  /// The measures of the buffer with [lo] and with [hi] units, if known.
  _Measure? loMeasure;
  _Measure? hiMeasure;

  /// Results in a row on the same side of the boundary, and that side.
  int streak = 0;
  bool? lastFit;

  /// Smallest growth of an aimed probe past [lo], doubled by each fit.
  int minStep = 1;

  List<int>? _cum;

  /// Text length of the first k units of [pending], for k up to its length.
  List<int> get cum {
    return _cum ??= [
      0,
      ...() sync* {
        var total = 0;
        for (final unit in pending) {
          total += unit.text?.length ?? 0;
          yield total;
        }
      }(),
    ];
  }

  void pendingChanged() => _cum = null;

  void fit(_Measure? measure) {
    loMeasure = measure;
    _result(fit: true);
    minStep *= 2;
  }

  void overflow(_Measure? measure) {
    hiMeasure = measure;
    _result(fit: false);
    minStep = 1;
  }

  void _result({required bool fit}) {
    streak = lastFit == fit ? streak + 1 : 1;
    lastFit = fit;
  }

  /// Forgets the bounds and measures for a fresh page.
  void reset() {
    p = 0;
    lo = 0;
    hi = pending.length;
    exponential = true;
    loMeasure = null;
    hiMeasure = null;
    streak = 0;
    lastFit = null;
    minStep = 1;
    pendingChanged();
  }
}
