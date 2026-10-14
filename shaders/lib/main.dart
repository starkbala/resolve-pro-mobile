import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Lock into DaVinci Resolve Landscape Workstation Orientation
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const ResolveProMobileApp());
}

class ResolveProMobileApp extends StatelessWidget {
  const ResolveProMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ResolvePro Mobile Studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF141417),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF5722),
          secondary: Color(0xFF29B6F6),
          surface: Color(0xFF1E1E24),
        ),
      ),
      home: const ResolveColorWorkstation(),
    );
  }
}

// --- DATA MODEL: SINGLE NODE GRADE STATE ---
class ColorNodeState {
  String id;
  String label;
  bool enabled;

  // Lift, Gamma, Gain, Offset: [R, G, B, Master Y]
  List<double> lift;
  List<double> gamma;
  List<double> gain;
  List<double> offset;

  // Primaries & HDR
  double contrast;
  double pivot;
  double saturation;
  double temp;
  double tint;
  double colorBoost;
  double shadows;
  double highlights;
  double lumMix;

  // CST & LUT
  int inputCST;
  int outputCST;
  int lutPreset;
  double lutStrength;

  // 3D Qualifier
  bool qualEnabled;
  double qualHueCenter;
  double qualHueWidth;
  double qualSoftness;
  double qualSatMin;
  double qualLumMin;

  // Power Window
  bool winEnabled;
  double winCenterX;
  double winCenterY;
  double winRadiusX;
  double winRadiusY;
  double winFeather;
  bool winInvert;

  ColorNodeState({
    required this.id,
    required this.label,
    this.enabled = true,
    List<double>? lift,
    List<double>? gamma,
    List<double>? gain,
    List<double>? offset,
    this.contrast = 1.0,
    this.pivot = 0.435,
    this.saturation = 1.0,
    this.temp = 0.0,
    this.tint = 0.0,
    this.colorBoost = 0.0,
    this.shadows = 0.0,
    this.highlights = 0.0,
    this.lumMix = 1.0,
    this.inputCST = 0,
    this.outputCST = 0,
    this.lutPreset = 0,
    this.lutStrength = 0.85,
    this.qualEnabled = false,
    this.qualHueCenter = 0.06,
    this.qualHueWidth = 0.18,
    this.qualSoftness = 0.08,
    this.qualSatMin = 0.15,
    this.qualLumMin = 0.10,
    this.winEnabled = false,
    this.winCenterX = 0.5,
    this.winCenterY = 0.5,
    this.winRadiusX = 0.35,
    this.winRadiusY = 0.35,
    this.winFeather = 0.25,
    this.winInvert = false,
  })  : lift = lift ?? [0.0, 0.0, 0.0, 0.0],
        gamma = gamma ?? [0.0, 0.0, 0.0, 0.0],
        gain = gain ?? [0.0, 0.0, 0.0, 0.0],
        offset = offset ?? [0.0, 0.0, 0.0, 0.0];

  void reset() {
    lift = [0.0, 0.0, 0.0, 0.0];
    gamma = [0.0, 0.0, 0.0, 0.0];
    gain = [0.0, 0.0, 0.0, 0.0];
    offset = [0.0, 0.0, 0.0, 0.0];
    contrast = 1.0;
    pivot = 0.435;
    saturation = 1.0;
    temp = 0.0;
    tint = 0.0;
    colorBoost = 0.0;
    shadows = 0.0;
    highlights = 0.0;
    lumMix = 1.0;
    inputCST = 0;
    outputCST = 0;
    lutPreset = 0;
    lutStrength = 0.85;
    qualEnabled = false;
    winEnabled = false;
    winInvert = false;
  }
}

class ResolveColorWorkstation extends StatefulWidget {
  const ResolveColorWorkstation({super.key});

  @override
  State<ResolveColorWorkstation> createState() =>
      _ResolveColorWorkstationState();
}

class _ResolveColorWorkstationState extends State<ResolveColorWorkstation> {
  ui.FragmentProgram? _program;
  ui.Image? _sourceImage;
  final GlobalKey _viewportKey = GlobalKey();

  // Multi-Node Pipeline
  final List<ColorNodeState> _nodes = [
    ColorNodeState(id: '01', label: '01: Primary Balance'),
    ColorNodeState(id: '02', label: '02: Skin / Secondary'),
    ColorNodeState(id: '03', label: '03: Film Look & CST'),
  ];
  int _activeNodeIndex = 0;

  // Workstation View Controls
  int _selectedDeckTab = 0; // 0:Primaries, 1:Log/HDR, 2:CST/LUT, 3:Qualifier, 4:Window, 5:Scopes
  bool _globalBypass = false;
  bool _showMatteHighlight = false;
  double _splitWipe = 0.0;
  bool _showNodePanel = true;
  bool _showScopesOverlay = false;

  ColorNodeState get _currentNode => _nodes[_activeNodeIndex];

  @override
  void initState() {
    super.initState();
    _initGpuEngine();
  }

  Future<void> _initGpuEngine() async {
    final program = await ui.FragmentProgram.fromAsset(
      'shaders/resolve_color_pipeline.frag',
    );
    final demoImage = await _generateReferenceTestChart(1280, 720);
    if (mounted) {
      setState(() {
        _program = program;
        _sourceImage = demoImage;
      });
    }
  }

  // Generates a Built-In Cinema Reference Frame (Skin tones, Sky, Color Patches, Luma Ramp)
  Future<ui.Image> _generateReferenceTestChart(int width, int height) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final w = width.toDouble();
    final h = height.toDouble();

    // 1. Sunset/Twilight Cinema Sky Gradient
    final skyPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(w, h * 0.75),
        [
          const Color(0xFF0D2B45),
          const Color(0xFF203C56),
          const Color(0xFF544E68),
          const Color(0xFF8D697A),
          const Color(0xFFD08159),
          const Color(0xFFFFAA5E),
        ],
        [0.0, 0.25, 0.45, 0.65, 0.85, 1.0],
      );
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), skyPaint);

    // 2. Simulated Subject Portrait / Skin Tone Reference Sphere in Center
    final skinPaint = Paint()
      ..shader = ui.Gradient.radial(
        Offset(w * 0.48, h * 0.42),
        h * 0.28,
        [
          const Color(0xFFF3C6A8),
          const Color(0xFFD89673),
          const Color(0xFFA86448),
          const Color(0xFF5D3222),
        ],
        [0.0, 0.45, 0.8, 1.0],
      );
    canvas.drawCircle(Offset(w * 0.5, h * 0.45), h * 0.24, skinPaint);

    // 3. Color Checker Patches (Bottom Above Ramp)
    final patches = [
      const Color(0xFF735244), // Dark Skin
      const Color(0xFFC29682), // Light Skin
      const Color(0xFF627A9D), // Blue Sky
      const Color(0xFF576C43), // Foliage
      const Color(0xFF8580B1), // Blue Flower
      const Color(0xFF67BDAA), // Bluish Green
      const Color(0xFFD67E2C), // Orange
      const Color(0xFF505BA6), // Purplish Blue
      const Color(0xFFC15A63), // Moderate Red
      const Color(0xFF5E3C6C), // Purple
      const Color(0xFF9DBC40), // Yellow Green
      const Color(0xFFE0A32E), // Orange Yellow
    ];
    final patchW = w / patches.length;
    for (int i = 0; i < patches.length; i++) {
      canvas.drawRect(
        Rect.fromLTWH(i * patchW, h * 0.76, patchW - 2, h * 0.12),
        Paint()..color = patches[i],
      );
    }

    // 4. 0-100 IRE Grayscale Dynamic Range Ramp at Bottom
    final rampPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, h * 0.9),
        Offset(w, h * 0.9),
        [Colors.black, Colors.white],
      );
    canvas.drawRect(Rect.fromLTWH(0, h * 0.89, w, h * 0.11), rampPaint);

    final picture = recorder.endRecording();
    return picture.toImage(width, height);
  }

  Future<void> _pickImageFromGallery() async {
    final picker = ImagePicker();
    final XFile? file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final Uint8List bytes = await file.readAsBytes();
    final ui.Codec codec = await ui.instantiateImageCodec(bytes);
    final ui.FrameInfo frame = await codec.getNextFrame();
    if (mounted) {
      setState(() {
        _sourceImage = frame.image;
      });
    }
  }

  Future<void> _exportGradedFrame() async {
    try {
      final boundary = _viewportKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return;
      final ui.Image image = await boundary.toImage(pixelRatio: 2.0);
      final ByteData? byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;
      final Uint8List pngBytes = byteData.buffer.asUint8List();
      await Gal.putImageBytes(
        pngBytes,
        name: 'ResolvePro_Grade_${DateTime.now().millisecondsSinceEpoch}',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF2E7D32),
            content: Text(
              'Graded High-Bitrate Frame Saved to Gallery!',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export Notice: $e')),
        );
      }
    }
  }

  void _addNode() {
    setState(() {
      final numStr = (_nodes.length + 1).toString().padLeft(2, '0');
      _nodes.add(ColorNodeState(id: numStr, label: '$numStr: Serial Node'));
      _activeNodeIndex = _nodes.length - 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _buildTopWorkstationBar(),
          Expanded(
            flex: 52,
            child: Row(
              children: [
                if (_showScopesOverlay) _buildLeftScopesDrawer(),
                Expanded(child: _buildCenterViewport()),
                if (_showNodePanel) _buildRightNodeGraphPanel(),
              ],
            ),
          ),
          _buildDeckModeSelectorBar(),
          Expanded(
            flex: 48,
            child: _buildBottomGradingDeck(),
          ),
        ],
      ),
    );
  }

  // --- TOP BAR: PROJECT PIPELINE, IMPORT, WIPE, BYPASS, EXPORT ---
  Widget _buildTopWorkstationBar() {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A20),
        border: Border(bottom: BorderSide(color: Color(0xFF2C2C35), width: 1)),
      ),
      child: Row(
        children: [
          const Icon(Icons.blur_circular, color: Color(0xFFFF5722), size: 18),
          const SizedBox(width: 6),
          const Text(
            'DAVINCI RESOLVE MOBILE STUDIO',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
              color: Color(0xFFE0E0E6),
            ),
          ),
          const SizedBox(width: 12),
          _topChipButton(
            icon: Icons.folder_open,
            label: 'Import RAW/Photo',
            onTap: _pickImageFromGallery,
          ),
          const SizedBox(width: 6),
          _topChipButton(
            icon: Icons.bar_chart,
            label: 'Scopes',
            active: _showScopesOverlay,
            onTap: () =>
                setState(() => _showScopesOverlay = !_showScopesOverlay),
          ),
          const SizedBox(width: 6),
          _topChipButton(
            icon: Icons.account_tree_outlined,
            label: 'Nodes (${_nodes.length})',
            active: _showNodePanel,
            onTap: () => setState(() => _showNodePanel = !_showNodePanel),
          ),
          const Spacer(),
          // Split Screen Wipe Slider
          const Text(
            'Wipe:',
            style: TextStyle(fontSize: 10, color: Colors.white60),
          ),
          SizedBox(
            width: 90,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 5.0),
              ),
              child: Slider(
                value: _splitWipe,
                min: 0.0,
                max: 1.0,
                activeColor: const Color(0xFFFF5722),
                onChanged: (v) => setState(() => _splitWipe = v),
              ),
            ),
          ),
          _topChipButton(
            icon: Icons.contrast,
            label: 'Highlight Matte',
            active: _showMatteHighlight,
            onTap: () =>
                setState(() => _showMatteHighlight = !_showMatteHighlight),
          ),
          const SizedBox(width: 6),
          _topChipButton(
            icon: Icons.visibility_off_outlined,
            label: 'Bypass',
            active: _globalBypass,
            activeColor: Colors.redAccent,
            onTap: () => setState(() => _globalBypass = !_globalBypass),
          ),
          const SizedBox(width: 6),
          _topChipButton(
            icon: Icons.refresh,
            label: 'Reset Node',
            onTap: () => setState(() => _currentNode.reset()),
          ),
          const SizedBox(width: 6),
          _topChipButton(
            icon: Icons.download_done,
            label: 'Export',
            active: true,
            activeColor: const Color(0xFF00897B),
            onTap: _exportGradedFrame,
          ),
        ],
      ),
    );
  }

  Widget _topChipButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool active = false,
    Color activeColor = const Color(0xFFFF5722),
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: active ? activeColor.withOpacity(0.22) : const Color(0xFF25252E),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: active ? activeColor : const Color(0xFF383844),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 12, color: active ? activeColor : Colors.white70),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: active ? Colors.white : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- CENTER VIEWPORT: GPU 32-BIT FLOAT REAL-TIME MONITOR ---
  Widget _buildCenterViewport() {
    if (_program == null || _sourceImage == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Container(
      color: const Color(0xFF0D0D10),
      child: Stack(
        alignment: Alignment.center,
        children: [
          InteractiveViewer(
            minScale: 0.8,
            maxScale: 8.0,
            child: AspectRatio(
              aspectRatio: _sourceImage!.width / _sourceImage!.height,
              child: RepaintBoundary(
                key: _viewportKey,
                child: CustomPaint(
                  painter: _ResolveGpuPipelinePainter(
                    program: _program!,
                    sourceImage: _sourceImage!,
                    nodes: _nodes,
                    activeNodeIndex: _activeNodeIndex,
                    splitWipe: _splitWipe,
                    bypass: _globalBypass,
                    showMatte: _showMatteHighlight,
                  ),
                ),
              ),
            ),
          ),
          // Power Window Interactive Touch Overlay when Window Tab is active
          if (_currentNode.winEnabled && _selectedDeckTab == 4)
            Positioned.fill(
              child: GestureDetector(
                onPanUpdate: (details) {
                  final box = context.findRenderObject() as RenderBox?;
                  if (box == null) return;
                  setState(() {
                    _currentNode.winCenterX = (_currentNode.winCenterX +
                            details.delta.dx / (box.size.width * 0.5))
                        .clamp(0.05, 0.95);
                    _currentNode.winCenterY = (_currentNode.winCenterY +
                            details.delta.dy / (box.size.height * 0.4))
                        .clamp(0.05, 0.95);
                  });
                },
                child: CustomPaint(
                  painter: _PowerWindowOverlayPainter(node: _currentNode),
                ),
              ),
            ),
          Positioned(
            left: 10,
            bottom: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                '32-Bit Float GPU | Active: ${_currentNode.label} | Pinch to 800% Zoom',
                style: const TextStyle(fontSize: 9, color: Colors.white60),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- LEFT COLLAPSIBLE PANEL: LIVE RGB PARADE & WAVEFORM SCOPES ---
  Widget _buildLeftScopesDrawer() {
    return Container(
      width: 195,
      padding: const EdgeInsets.all(8),
      decoration: const BoxDecoration(
        color: Color(0xFF18181D),
        border: Border(right: BorderSide(color: Color(0xFF2C2C35))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'VIDEO SCOPES (RGB PARADE)',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.bold,
              color: Colors.white54,
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0A0A0D),
                border: Border.all(color: const Color(0xFF2D2D36)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: CustomPaint(
                size: Size.infinite,
                painter: _ScopesParadePainter(node: _currentNode),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- RIGHT COLLAPSIBLE PANEL: DAVINCI NODE GRAPH PIPELINE ---
  Widget _buildRightNodeGraphPanel() {
    return Container(
      width: 215,
      padding: const EdgeInsets.all(8),
      decoration: const BoxDecoration(
        color: Color(0xFF18181D),
        border: Border(left: BorderSide(color: Color(0xFF2C2C35))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'NODE GRAPH (DAG)',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: Colors.white54,
                ),
              ),
              InkWell(
                onTap: _addNode,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF5722).withOpacity(0.25),
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(color: const Color(0xFFFF5722)),
                  ),
                  child: const Text(
                    '+ Serial Node',
                    style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height:
