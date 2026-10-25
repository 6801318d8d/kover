import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Marks the widget subtree whose [RenderBox] size should be reported by
/// [HeadlessMeasurePipeline.measure].
class MeasureTarget extends SingleChildRenderObjectWidget {
  const MeasureTarget({super.key, super.child});

  @override
  RenderMeasureTarget createRenderObject(BuildContext context) {
    return RenderMeasureTarget();
  }
}

class RenderMeasureTarget extends RenderProxyBox {}

/// Thrown when the measure widget tree fails to build and the framework
/// silently swaps in an [ErrorWidget]. Without this check the resulting
/// (near-zero) size would be treated as "content fits".
class MeasureTreeBuildException implements Exception {
  final String message;

  const MeasureTreeBuildException(this.message);

  @override
  String toString() => 'MeasureTreeBuildException: $message';
}

/// A headless render pipeline for measuring widget layouts outside the main
/// widget tree.
///
/// Owns its own [PipelineOwner] and [BuildOwner], so measurement is driven
/// synchronously via [measure] instead of being bound to the frame schedule.
class HeadlessMeasurePipeline {
  PipelineOwner? _pipelineOwner;
  BuildOwner? _buildOwner;
  RenderView? _renderView;
  RenderObjectToWidgetElement<RenderBox>? _rootElement;

  /// The target found by the last measure; it usually survives between
  /// measures of the same widget tree.
  RenderMeasureTarget? _target;

  /// The viewport size the pipeline is currently attached to.
  Size? viewportSize;

  bool get isAttached => _renderView != null;

  /// Attaches the pipeline to a viewport of [size]. Reconfigures the
  /// existing [RenderView] if the size changed.
  void attach({required Size size, required double devicePixelRatio}) {
    final configuration = ViewConfiguration(
      logicalConstraints: BoxConstraints.tight(size),
      physicalConstraints: BoxConstraints.tight(size * devicePixelRatio),
      devicePixelRatio: devicePixelRatio,
    );

    if (isAttached) {
      _reset();
    }

    viewportSize = size;
    _pipelineOwner = PipelineOwner();
    _buildOwner = BuildOwner(focusManager: FocusManager());
    _renderView = RenderView(
      configuration: configuration,
      view: PlatformDispatcher.instance.views.first,
    );
    _renderView!.attach(_pipelineOwner!);
    _renderView!.prepareInitialFrame();
  }

  /// Lays out [widget] and returns the size of the [RenderMeasureTarget]
  /// found in its render tree, or [Size.zero] if there is none.
  Size measure(Widget widget) {
    assert(
      _renderView != null,
      'attach() must be called before measure()',
    );

    // A widget failing to build is reported before the framework swaps in
    // an ErrorWidget: catch the report instead of searching the render tree.
    FlutterErrorDetails? buildError;
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      buildError ??= details;
      previousOnError?.call(details);
    };
    try {
      _rootElement = RenderObjectToWidgetAdapter<RenderBox>(
        container: _renderView!,
        child: widget,
      ).attachToRenderTree(_buildOwner!, _rootElement);

      _buildOwner!.buildScope(_rootElement!);
      _buildOwner!.finalizeTree();
    } finally {
      FlutterError.onError = previousOnError;
    }

    if (buildError case final error?) {
      throw MeasureTreeBuildException(error.exceptionAsString());
    }

    _pipelineOwner!.flushLayout();

    final rootChild = _renderView!.child;
    if (rootChild == null) return Size.zero;

    final cached = _target;
    final target = cached != null && cached.attached
        ? cached
        : _target = _findMeasureTarget(rootChild);
    return target?.hasSize == true ? target!.size : Size.zero;
  }

  RenderMeasureTarget? _findMeasureTarget(RenderObject node) {
    if (node is RenderMeasureTarget) return node;

    RenderMeasureTarget? found;
    node.visitChildren((child) {
      found ??= _findMeasureTarget(child);
    });
    return found;
  }

  /// Tears down the pipeline so the next [attach] starts from a clean
  /// [BuildOwner] and element tree.
  void _reset() {
    if (_rootElement != null) {
      try {
        // Unmount the element tree by attaching an empty adapter.
        RenderObjectToWidgetAdapter<RenderBox>(
          container: _renderView!,
        ).attachToRenderTree(_buildOwner!, _rootElement);
        _buildOwner!.buildScope(_rootElement!);
        _buildOwner!.finalizeTree();
      } catch (_) {
        // Dirty elements orphaned by the previous run; abandon the owner.
      }
      _rootElement = null;
    }
    _target = null;

    _renderView?.detach();
    _renderView = null;
    _buildOwner?.focusManager.dispose();
    _buildOwner = null;
    _pipelineOwner?.dispose();
    _pipelineOwner = null;
    viewportSize = null;
  }

  void dispose() => _reset();
}
