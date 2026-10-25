/*
 *     Copyright (C) 2026 Víctor Castilla
 *
 *     DSK Play is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     DSK Play is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 *
 *     For more information about DSK Play, including how to contribute,
 *     please visit: https://dskmusic.com or https://github.com/dskmusic
 */

import 'dart:math' as math;

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

// ---------------------------------------------------------------------------
// Perillas de calibracion. Esto es decoracion: lo correcto es lo que se ve
// bien en el movil, no lo que dice la teoria. Tocar aqui antes que el codigo
// de cada temporada.
// ---------------------------------------------------------------------------

/// Altura relativa donde se apoyan los elementos "de suelo" (calabazas,
/// coronas, hoguera, procesion). Bastante abajo a proposito: asoman por
/// detras de la barra de navegacion en vez de flotar sobre ella.
const _groundLine = 0.90;

/// Techo de opacidad global. Subirlo hace la decoracion mas evidente.
const _maxAlpha = 1.0;

/// Cuanto se atenua todo en tema claro, donde el mismo adorno canta el doble.
const _lightThemeFactor = 0.7;

/// Un ciclo completo de la animacion. Mas largo = todo mas calmado.
const _cycle = Duration(seconds: 24);

/// Por encima de esta intensidad se pintan tambien los elementos grandes y
/// fijos (luna, calabazas, guirnalda); por debajo solo lo que flota.
const _fullSceneAt = 0.75;

/// Cuanto hay que mantener pulsado un encabezado para abrir el menu oculto.
const _secretHold = Duration(seconds: 2);

/// Margen que se le da al arranque antes de pintar el primer frame. Los
/// desenfoques y degradados compiten con la carga inicial (Hive, audio,
/// portadas) y se notaba un tiron al abrir. Corto a proposito: lo que suaviza
/// la entrada es el fundido, no la espera.
const _warmUp = Duration(milliseconds: 1200);

/// Fundido de entrada. Se usa al arrancar y tambien al cambiar de temporada
/// desde el menu, para que nada aparezca de golpe.
const _fadeIn = Duration(seconds: 3);

// ---------------------------------------------------------------------------
// Temporadas
// ---------------------------------------------------------------------------

/// Añadir una fiesta nueva son tres pasos: un valor aqui, su rango en
/// [seasonForDate] y su `case` en [_DecorPainter.paint] con su pintor.
/// El orden de los valores es el del menu: calendario de enero a diciembre.
enum Season {
  none('Ninguna'),
  newYear('Año Nuevo'),
  epiphany('Reyes'),
  valentines('San Valentín'),
  musicDay('Día de la Música'),
  halloween('Halloween'),
  christmas('Navidad'),
  birthday('Cumpleaños');

  const Season(this.label);

  final String label;
}

/// Cumpleaños de la familia, en formato mes*100+dia. Van todos a la misma
/// decoracion y a una sola entrada del menu: lo que cambia es el dia, no el
/// adorno. Los rangos que cruzan de mes (1129-1201) funcionan igual porque
/// los numeros intermedios no existen como fecha.
const _birthdays = [
  (207, 209), // Víctor
  (330, 401), // Lucía
  (422, 424), // Alicia
  (1129, 1201), // Eva
];

/// Que fiesta toca por calendario. Fechas españolas.
///
/// Los cumpleaños van primero: pisan a la Navidad (Eva, el 1 de diciembre).
Season seasonForDate(DateTime d) {
  final md = d.month * 100 + d.day;

  for (final (from, to) in _birthdays) {
    if (md >= from && md <= to) return Season.birthday;
  }

  if (md >= 1024 && md <= 1102) return Season.halloween;
  if (md >= 1201 && md <= 1226) return Season.christmas;
  if (md >= 1227 || md <= 102) return Season.newYear;
  if (md >= 103 && md <= 106) return Season.epiphany;
  if (md >= 212 && md <= 215) return Season.valentines;
  if (md >= 620 && md <= 622) return Season.musicDay;

  return Season.none;
}

/// Temporada forzada desde el menu oculto. `null` es el comportamiento
/// normal: la que toque por fecha.
final seasonOverride = ValueNotifier<Season?>(_readOverride());

Season? _readOverride() {
  final name = Hive.box('settings').get('seasonOverride') as String?;
  if (name == null) return null;
  return Season.values.firstWhere(
    (s) => s.name == name,
    orElse: () => Season.none,
  );
}

void setSeasonOverride(Season? season) {
  seasonOverride.value = season;
  final box = Hive.box('settings');
  if (season == null) {
    box.delete('seasonOverride');
  } else {
    box.put('seasonOverride', season.name);
  }
}

Season get currentSeason =>
    seasonOverride.value ?? seasonForDate(DateTime.now());

/// Cuanto adorno admite lo que hay delante: 1 en pantallas normales, menos en
/// el reproductor (mandan los controles) y 0 en karaoke (hay que leer). Lo
/// fijan esas pantallas en su `initState` y lo devuelven en `dispose`.
final decorIntensity = ValueNotifier<double>(1);

// ---------------------------------------------------------------------------
// La capa
// ---------------------------------------------------------------------------

/// Capa de adorno sobre toda la app. Va en el `builder` del MaterialApp, asi
/// que cubre tambien lo que se empuja con Navigator (el reproductor). Nunca
/// recibe toques y se para sola cuando la app pasa a segundo plano.
class SeasonalDecor extends StatefulWidget {
  const SeasonalDecor({super.key, required this.child});

  final Widget child;

  @override
  State<SeasonalDecor> createState() => _SeasonalDecorState();
}

class _SeasonalDecorState extends State<SeasonalDecor>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _cycle,
  );

  /// Opacidad de entrada. Va aparte del ciclo porque no se repite.
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: _fadeIn,
  );

  bool _foreground = true;
  bool _warm = false;
  Season? _builtFor;
  List<_Particle> _particles = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    seasonOverride.addListener(_onChanged);
    decorIntensity.addListener(_onChanged);
    // Nada de pintar durante el arranque: el adorno espera a que la app este
    // viva y entra sola despues.
    Future.delayed(_warmUp, () {
      if (!mounted) return;
      _warm = true;
      _onChanged();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    seasonOverride.removeListener(_onChanged);
    decorIntensity.removeListener(_onChanged);
    _fade.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _updateTicker();
  }

  void _onChanged() {
    // Cambio de temporada desde el menu: la nueva tambien entra fundida.
    if (_builtFor != null && _builtFor != currentSeason) _fade.forward(from: 0);
    _updateTicker();
    // Las pantallas tocan decorIntensity en su initState, que corre dentro de
    // la fase de build: reconstruir ahi mismo revienta con "setState called
    // during build". Se deja para el frame siguiente.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  void _updateTicker() {
    final on =
        _warm &&
        _foreground &&
        currentSeason != Season.none &&
        decorIntensity.value > 0;
    if (on && !_controller.isAnimating) {
      _controller.repeat();
      if (_fade.value == 0) _fade.forward();
    } else if (!on && _controller.isAnimating) {
      _controller.stop();
    }
  }

  List<_Particle> _particlesFor(Season season) {
    if (_builtFor != season) {
      _builtFor = season;
      // Semilla fija: el reparto es aleatorio pero siempre el mismo, asi no
      // "salta" cuando la capa se reconstruye.
      _particles = _buildParticles(season, math.Random(7));
    }
    return _particles;
  }

  @override
  Widget build(BuildContext context) {
    final season = currentSeason;
    final intensity = decorIntensity.value;
    final show = _warm && season != Season.none && intensity > 0;

    // El Stack esta siempre, con o sin adorno: si la forma del arbol cambiara
    // segun la temporada, apagarla desmontaria el Navigator entero y con el
    // toda la navegacion.
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (show)
          IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _DecorPainter(
                  season: season,
                  progress: _controller,
                  particles: _particlesFor(season),
                  intensity: intensity,
                  dark: Theme.of(context).brightness == Brightness.dark,
                  fadeIn: _fade,
                  topInset: MediaQuery.paddingOf(context).top,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Menu oculto
// ---------------------------------------------------------------------------

/// Abre el menu de decoracion manteniendo pulsados dos segundos. Envuelve el
/// `title` de los AppBar; dos segundos es bastante mas que un toque largo
/// normal, asi que no se abre sin querer.
class SeasonalDecorTrigger extends StatelessWidget {
  const SeasonalDecorTrigger({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(duration: _secretHold),
              (instance) => instance.onLongPress = () {
                showSeasonalDecorPicker(context);
              },
            ),
      },
      child: child,
    );
  }
}

/// Sin traducir a proposito: es un menu de pruebas, no interfaz de usuario.
Future<void> showSeasonalDecorPicker(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Decoración de temporada'),
      content: SingleChildScrollView(
        child: ValueListenableBuilder<Season?>(
          valueListenable: seasonOverride,
          builder: (context, override, _) {
            final auto = seasonForDate(DateTime.now());
            Widget option(Season? value, String label) => ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                override == value
                    ? FluentIcons.checkmark_circle_24_filled
                    : FluentIcons.circle_24_regular,
              ),
              title: Text(label),
              onTap: () => setSeasonOverride(value),
            );

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                option(null, 'Automática (hoy: ${auto.label})'),
                const Divider(height: 1),
                for (final s in Season.values) option(s, s.label),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            setSeasonOverride(null);
            Navigator.pop(context);
          },
          child: const Text('Restaurar original'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cerrar'),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Particulas
// ---------------------------------------------------------------------------

class _Particle {
  const _Particle({
    required this.x,
    required this.y,
    required this.scale,
    required this.speed,
    required this.phase,
    required this.tint,
  });

  /// Posicion base 0..1; que signifique exactamente depende de la temporada.
  final double x;
  final double y;
  final double scale;
  final double speed;
  final double phase;
  final int tint;
}

List<_Particle> _buildParticles(Season season, math.Random r) {
  final count = switch (season) {
    Season.none => 0,
    Season.halloween => 7,
    Season.christmas => 26,
    Season.newYear => 28,
    Season.epiphany => 16,
    Season.valentines => 14,
    Season.musicDay => 12,
    Season.birthday => 12,
  };
  return List.generate(
    count,
    (_) => _Particle(
      x: r.nextDouble(),
      y: r.nextDouble(),
      scale: 0.6 + r.nextDouble() * 0.8,
      speed: 0.5 + r.nextDouble(),
      phase: r.nextDouble(),
      tint: r.nextInt(4),
    ),
  );
}

// ---------------------------------------------------------------------------
// Pintor
// ---------------------------------------------------------------------------

class _DecorPainter extends CustomPainter {
  _DecorPainter({
    required this.season,
    required this.progress,
    required this.particles,
    required this.intensity,
    required this.dark,
    required this.topInset,
    required this.fadeIn,
  }) : super(repaint: progress);

  final Season season;
  final Animation<double> progress;
  final List<_Particle> particles;
  final double intensity;
  final bool dark;

  /// Opacidad de entrada, 0 a 1.
  final Animation<double> fadeIn;

  /// Alto de la barra de estado: con el se calcula donde cae el titulo del
  /// AppBar, que es por donde pasa la guirnalda.
  final double topInset;

  /// Linea en la que esta el texto del encabezado.
  double get _titleLine => topInset + kToolbarHeight * 0.52;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    final o =
        intensity.clamp(0.0, 1.0) *
        _maxAlpha *
        (dark ? 1.0 : _lightThemeFactor) *
        Curves.easeIn.transform(fadeIn.value);
    if (o <= 0) return;
    switch (season) {
      case Season.none:
        return;
      case Season.halloween:
        _halloween(canvas, size, t, o);
      case Season.christmas:
        _christmas(canvas, size, t, o);
      case Season.newYear:
        _newYear(canvas, size, t, o);
      case Season.epiphany:
        _epiphany(canvas, size, t, o);
      case Season.valentines:
        _valentines(canvas, size, t, o);
      case Season.musicDay:
        _musicDay(canvas, size, t, o);
      case Season.birthday:
        _birthday(canvas, size, t, o);
    }
  }

  @override
  bool shouldRepaint(_DecorPainter old) =>
      old.season != season ||
      old.intensity != intensity ||
      old.dark != dark ||
      old.topInset != topInset ||
      old.particles != particles;

  // --- Halloween ----------------------------------------------------------

  void _halloween(Canvas canvas, Size size, double t, double o) {
    if (intensity >= _fullSceneAt) {
      final moon = Offset(size.width * 0.84, size.height * 0.085);
      _glow(canvas, moon, size.width * 0.3, const Color(0xFFE8C87A), 0.2 * o);
      canvas.drawCircle(
        moon,
        size.width * 0.072,
        Paint()..color = const Color(0xFFD9BE86).withValues(alpha: 0.45 * o),
      );
      _pumpkinRow(canvas, size, t, o);
    }

    final paint = Paint()
      ..color = const Color(0xFF8E7BC4).withValues(alpha: 0.45 * o);
    for (final p in particles) {
      final u = (t * p.speed + p.phase) % 1.0;
      // Cruzan de lado a lado, entrando y saliendo de pantalla.
      final travel = 1.3 * u - 0.15;
      final x = (p.tint.isEven ? travel : 1 - travel) * size.width;
      final y =
          (0.05 + p.y * 0.6 + 0.035 * math.sin(u * math.pi * 4 + p.phase * 6)) *
          size.height;
      // Aleteo: vistos de frente las alas se acortan, por eso encoge en X.
      final flap =
          0.45 + 0.55 * (0.5 + 0.5 * math.sin(u * math.pi * 30 + p.phase * 9));
      final s = size.width * 0.07 * p.scale;
      canvas
        ..save()
        ..translate(x, y)
        ..scale(flap * s, s)
        ..drawPath(_batPath, paint)
        ..restore();
    }
  }

  void _pumpkinRow(Canvas canvas, Size size, double t, double o) {
    final baseY = size.height * _groundLine;
    for (var i = 0; i < 4; i++) {
      final cx = size.width * (0.13 + i * 0.25);
      final h = size.width * (i.isEven ? 0.15 : 0.13);
      // Dos senos de periodo distinto: parpadeo de vela, no latido regular.
      final flicker =
          0.5 +
          0.5 *
              math.sin(t * math.pi * 2 * 6 + i * 1.7) *
              math.sin(t * math.pi * 2 * 11 + i);
      _glow(
        canvas,
        Offset(cx, baseY - h * 0.3),
        h * 1.7,
        const Color(0xFFFF8A2B),
        (0.1 + 0.09 * flicker) * o,
      );
      _pumpkin(canvas, Offset(cx, baseY - h * 0.5), h, o, flicker);
    }
  }

  void _pumpkin(Canvas canvas, Offset c, double h, double o, double flicker) {
    final w = h * 1.2;
    // Difuminadas a proposito: asi leen como fondo y no como dibujo encima.
    final body = Paint()
      ..color = const Color(0xFFE2761B).withValues(alpha: 0.33 * o)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5);
    canvas
      ..drawRRect(
        RRect.fromRectXY(
          Rect.fromCenter(
            center: c.translate(0, -h * 0.56),
            width: w * 0.1,
            height: h * 0.26,
          ),
          2,
          2,
        ),
        Paint()..color = const Color(0xFF6B4A2B).withValues(alpha: 0.3 * o),
      )
      ..drawOval(Rect.fromCenter(center: c, width: w, height: h), body)
      ..drawOval(
        Rect.fromCenter(
          center: c.translate(-w * 0.26, 0),
          width: w * 0.56,
          height: h * 0.93,
        ),
        body,
      )
      ..drawOval(
        Rect.fromCenter(
          center: c.translate(w * 0.26, 0),
          width: w * 0.56,
          height: h * 0.93,
        ),
        body,
      );

    final face = Paint()
      ..color = const Color(
        0xFFFFD27A,
      ).withValues(alpha: (0.25 + 0.3 * flicker) * o)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.2);
    canvas
      ..drawPath(_triangle(c.translate(-w * 0.2, -h * 0.12), h * 0.18), face)
      ..drawPath(_triangle(c.translate(w * 0.2, -h * 0.12), h * 0.18), face)
      ..drawPath(_triangle(c.translate(0, h * 0.02), h * 0.13), face);

    final left = c.dx - w * 0.28;
    final right = c.dx + w * 0.28;
    final top = c.dy + h * 0.15;
    final bottom = c.dy + h * 0.3;
    final mouth = Path()..moveTo(left, top);
    for (var i = 1; i <= 12; i++) {
      mouth.lineTo(left + (right - left) * i / 12, i.isOdd ? bottom : top);
    }
    canvas.drawPath(mouth..close(), face);
  }

  // --- Navidad ------------------------------------------------------------

  void _christmas(Canvas canvas, Size size, double t, double o) {
    if (intensity >= _fullSceneAt) _lights(canvas, size, t, o);

    final paint = Paint()..color = Colors.white.withValues(alpha: 0.45 * o);
    for (final p in particles) {
      final u = (t * p.speed * 0.6 + p.phase) % 1.0;
      final y = u * (size.height + 40) - 20;
      final x =
          (p.x + 0.035 * math.sin(u * math.pi * 4 + p.phase * 6)) * size.width;
      final r = size.width * 0.009 * p.scale;
      if (p.scale > 1.15) {
        _snowflake(canvas, Offset(x, y), r * 2.4, paint.color, u + p.phase);
      } else {
        canvas.drawCircle(Offset(x, y), r, paint);
      }
    }
  }

  void _snowflake(Canvas canvas, Offset c, double r, Color color, double spin) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = r * 0.17
      ..strokeCap = StrokeCap.round;
    canvas
      ..save()
      ..translate(c.dx, c.dy)
      ..rotate(spin * math.pi * 2);
    for (var i = 0; i < 3; i++) {
      canvas
        ..drawLine(Offset(-r, 0), Offset(r, 0), paint)
        ..rotate(math.pi / 3);
    }
    canvas.restore();
  }

  /// Guirnalda a la altura del encabezado: el cable serpentea cruzando la
  /// linea del texto, asi que pasa por delante y por detras de las letras y
  /// parece enredado en ellas.
  void _lights(Canvas canvas, Size size, double t, double o) {
    final line = _titleLine;
    final sag = kToolbarHeight * 0.3;
    final wire = Path()..moveTo(0, line - sag * 0.6);
    const arcs = 4;
    for (var i = 0; i < arcs; i++) {
      final x0 = size.width * i / arcs;
      final x1 = size.width * (i + 1) / arcs;
      wire.quadraticBezierTo(
        (x0 + x1) / 2,
        line + (i.isEven ? sag : -sag) * 1.6,
        x1,
        line + (i.isEven ? -sag * 0.6 : sag * 0.6),
      );
    }
    canvas.drawPath(
      wire,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..color = Colors.white.withValues(alpha: 0.2 * o),
    );

    for (final metric in wire.computeMetrics()) {
      const bulbs = 14;
      for (var i = 0; i <= bulbs; i++) {
        final pos = metric
            .getTangentForOffset(metric.length * i / bulbs)
            ?.position;
        if (pos == null) continue;
        final color = _xmasColors[i % _xmasColors.length];
        final blink =
            0.4 + 0.6 * (0.5 + 0.5 * math.sin(t * math.pi * 2 * 3 + i * 1.15));
        _glow(canvas, pos, size.width * 0.03, color, 0.22 * blink * o);
        canvas.drawCircle(
          pos,
          size.width * 0.008,
          Paint()..color = color.withValues(alpha: (0.4 + 0.45 * blink) * o),
        );
      }
    }
  }

  // --- Año Nuevo ----------------------------------------------------------

  void _newYear(Canvas canvas, Size size, double t, double o) {
    for (final p in particles) {
      final u = (t * p.speed * 0.7 + p.phase) % 1.0;
      final y = u * (size.height + 30) - 15;
      final x =
          (p.x + 0.045 * math.sin(u * math.pi * 3 + p.phase * 7)) * size.width;
      final w = size.width * 0.009 * p.scale;
      canvas
        ..save()
        ..translate(x, y)
        ..rotate(u * math.pi * 6 + p.phase * 3)
        ..drawRect(
          Rect.fromCenter(center: Offset.zero, width: w, height: w * 2.2),
          Paint()..color = _partyColors[p.tint].withValues(alpha: 0.5 * o),
        )
        ..restore();
    }

    if (intensity < _fullSceneAt) return;
    for (var i = 0; i < 3; i++) {
      final u = (t * 1.8 + i / 3) % 1.0;
      if (u > 0.7) continue; // el resto del ciclo, apagado
      final e = Curves.easeOutCubic.transform(u / 0.7);
      final center = Offset(
        size.width * (0.22 + 0.28 * i),
        size.height * (0.1 + 0.08 * (i % 2)),
      );
      final radius = size.width * 0.22 * e;
      final alpha = (1 - e) * 0.55 * o;
      final color = _partyColors[i % _partyColors.length];
      final paint = Paint()
        ..color = color.withValues(alpha: alpha)
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round;
      for (var k = 0; k < 14; k++) {
        final angle = k / 14 * math.pi * 2;
        final dir = Offset(math.cos(angle), math.sin(angle));
        canvas.drawLine(
          center + dir * (radius * 0.55),
          center + dir * radius,
          paint,
        );
      }
      _glow(canvas, center, radius * 0.9, color, alpha * 0.5);
    }
  }

  // --- Reyes --------------------------------------------------------------

  void _epiphany(Canvas canvas, Size size, double t, double o) {
    const gold = Color(0xFFFFD36E);

    for (final p in particles) {
      final u = (t * p.speed * 0.4 + p.phase) % 1.0;
      final y = (1.05 - 1.15 * u) * size.height;
      final x =
          (p.x + 0.03 * math.sin(u * math.pi * 3 + p.phase * 6)) * size.width;
      final fade = math.sin(u * math.pi).clamp(0.0, 1.0);
      canvas.drawCircle(
        Offset(x, y),
        size.width * 0.005 * p.scale,
        Paint()..color = gold.withValues(alpha: 0.4 * fade * o),
      );
    }

    // Estrella de Belen cruzando en diagonal.
    final u = (t * 0.9) % 1.0;
    final star = Offset(
      size.width * (1.15 - 1.4 * u),
      size.height * (0.06 + 0.2 * u),
    );
    final fade = math.sin(u * math.pi).clamp(0.0, 1.0);
    final tail = Path()
      ..moveTo(star.dx, star.dy)
      ..lineTo(star.dx + size.width * 0.28, star.dy - size.height * 0.045)
      ..lineTo(star.dx + size.width * 0.28, star.dy + size.height * 0.012)
      ..close();
    canvas.drawPath(
      tail,
      Paint()
        ..color = gold.withValues(alpha: 0.13 * fade * o)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    _glow(canvas, star, size.width * 0.13, gold, 0.3 * fade * o);
    canvas.drawPath(
      _star(star, size.width * 0.035),
      Paint()..color = gold.withValues(alpha: 0.65 * fade * o),
    );

    if (intensity < _fullSceneAt) return;
    final baseY = size.height * _groundLine;
    for (var i = 0; i < 3; i++) {
      final c = Offset(size.width * (0.24 + i * 0.26), baseY);
      final w = size.width * 0.12;
      final color = _crownColors[i];
      _glow(canvas, c, w * 1.4, color, 0.1 * o);
      canvas.drawPath(
        _crown(c, w),
        Paint()
          ..color = color.withValues(alpha: 0.33 * o)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      );
    }
  }

  // --- San Valentin -------------------------------------------------------

  void _valentines(Canvas canvas, Size size, double t, double o) {
    for (final p in particles) {
      final u = (t * p.speed * 0.5 + p.phase) % 1.0;
      final y = (1.1 - 1.25 * u) * size.height;
      final x =
          (p.x + 0.05 * math.sin(u * math.pi * 3 + p.phase * 6)) * size.width;
      final beat = 1 + 0.12 * math.sin(u * math.pi * 2 * 14 + p.phase * 5);
      final s = size.width * 0.05 * p.scale * beat;
      final fade = math.sin(u * math.pi).clamp(0.0, 1.0);
      canvas
        ..save()
        ..translate(x, y)
        ..rotate(0.25 * math.sin(u * math.pi * 2 + p.phase * 4))
        ..scale(s)
        ..drawPath(
          _heartPath,
          Paint()
            ..color = _loveColors[p.tint].withValues(alpha: 0.45 * fade * o),
        )
        ..restore();
    }
  }

  // --- Dia de la Musica ---------------------------------------------------

  void _musicDay(Canvas canvas, Size size, double t, double o) {
    for (final p in particles) {
      final u = (t * p.speed * 0.45 + p.phase) % 1.0;
      final y = (1.1 - 1.25 * u) * size.height;
      final x =
          (p.x + 0.06 * math.sin(u * math.pi * 2.5 + p.phase * 6)) * size.width;
      final fade = math.sin(u * math.pi).clamp(0.0, 1.0);
      final s = size.width * 0.09 * p.scale;
      canvas
        ..save()
        ..translate(x, y)
        ..rotate(0.3 * math.sin(u * math.pi * 2 + p.phase * 5))
        ..scale(s)
        ..drawPath(
          p.tint.isEven ? _eighthNotePath : _beamedNotesPath,
          Paint()
            ..color = _musicColors[p.tint].withValues(alpha: 0.5 * fade * o),
        )
        ..restore();
    }

    if (intensity < _fullSceneAt) return;
    // Pulso de sonido saliendo de abajo, como un altavoz.
    final center = Offset(size.width * 0.5, size.height * _groundLine);
    for (var i = 0; i < 3; i++) {
      final u = (t * 2 + i / 3) % 1.0;
      final r = size.width * (0.1 + 0.45 * u);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: r),
        math.pi * 1.15,
        math.pi * 0.7,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(
            0xFF7BE0FF,
          ).withValues(alpha: 0.18 * (1 - u) * o),
      );
    }
  }

  // --- Cumpleaños ---------------------------------------------------------

  void _birthday(Canvas canvas, Size size, double t, double o) {
    for (final p in particles) {
      final u = (t * p.speed * 0.3 + p.phase) % 1.0;
      final y = (1.2 - 1.45 * u) * size.height;
      final sway = 0.05 * math.sin(u * math.pi * 2.5 + p.phase * 6);
      final x = (p.x + sway) * size.width;
      final w = size.width * 0.07 * p.scale;
      final color = _partyColors[p.tint];
      final alpha = 0.4 * o;

      // La cuerda sale del nudo y se curva hacia donde viene el balanceo.
      canvas.drawPath(
        Path()
          ..moveTo(x, y + w * 0.68)
          ..quadraticBezierTo(
            x - sway * size.width * 0.5,
            y + w * 1.3,
            x + sway * size.width * 0.3,
            y + w * 1.9,
          ),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = color.withValues(alpha: alpha * 0.6),
      );
      canvas
        ..drawOval(
          Rect.fromCenter(
            center: Offset(x, y),
            width: w,
            height: w * 1.22,
          ),
          Paint()..color = color.withValues(alpha: alpha),
        )
        ..drawPath(
          _triangle(Offset(x, y + w * 0.66), w * 0.22),
          Paint()..color = color.withValues(alpha: alpha),
        )
        // Brillo: lo que hace que parezca globo y no huevo.
        ..drawOval(
          Rect.fromCenter(
            center: Offset(x - w * 0.22, y - w * 0.28),
            width: w * 0.2,
            height: w * 0.3,
          ),
          Paint()..color = Colors.white.withValues(alpha: alpha * 0.5),
        );
    }

    if (intensity < _fullSceneAt) return;
    // Confeti cayendo del borde de arriba.
    for (var i = 0; i < 16; i++) {
      final u = (t * 1.4 + i / 16) % 1.0;
      final x = size.width * ((i * 0.37) % 1.0);
      final y = u * size.height * 0.45;
      final w = size.width * 0.008;
      canvas
        ..save()
        ..translate(x, y)
        ..rotate(u * math.pi * 8 + i)
        ..drawRect(
          Rect.fromCenter(center: Offset.zero, width: w, height: w * 2),
          Paint()
            ..color = _partyColors[i % _partyColors.length].withValues(
              alpha: 0.4 * (1 - u) * o,
            ),
        )
        ..restore();
    }
  }

  // --- Utilidades ---------------------------------------------------------

  void _glow(Canvas canvas, Offset c, double radius, Color color, double a) {
    if (a <= 0 || radius <= 0) return;
    canvas.drawCircle(
      c,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [color.withValues(alpha: a), color.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: c, radius: radius)),
    );
  }
}

// ---------------------------------------------------------------------------
// Formas. Las normalizadas (unidad = 1) las escala el canvas; las que reciben
// centro y tamaño se usan sueltas.
// ---------------------------------------------------------------------------

/// Murcielago de frente: cuerpo, dos orejas y las dos alas, que son la misma
/// curva con la X invertida.
final Path _batPath = Path()
  ..addOval(Rect.fromCenter(center: Offset.zero, width: 0.26, height: 0.46))
  ..addPolygon(const [
    Offset(-0.11, -0.17),
    Offset(-0.16, -0.37),
    Offset(-0.02, -0.21),
  ], true)
  ..addPolygon(const [
    Offset(0.11, -0.17),
    Offset(0.16, -0.37),
    Offset(0.02, -0.21),
  ], true)
  ..addPath(_batWing(1), Offset.zero)
  ..addPath(_batWing(-1), Offset.zero);

Path _batWing(double dir) => Path()
  ..moveTo(0.07 * dir, -0.1)
  ..quadraticBezierTo(0.45 * dir, -0.52, 1 * dir, -0.34)
  ..quadraticBezierTo(0.84 * dir, -0.06, 0.74 * dir, 0.2)
  ..quadraticBezierTo(0.64 * dir, -0.04, 0.48 * dir, -0.04)
  ..quadraticBezierTo(0.44 * dir, 0.1, 0.33 * dir, 0.28)
  ..quadraticBezierTo(0.25 * dir, 0.04, 0.12 * dir, 0.06)
  ..close();

final Path _heartPath = Path()
  ..moveTo(0, 0.38)
  ..cubicTo(-0.62, -0.1, -0.32, -0.6, 0, -0.22)
  ..cubicTo(0.32, -0.6, 0.62, -0.1, 0, 0.38)
  ..close();

/// Corchea: cabeza, plica y banderin.
final Path _eighthNotePath = Path()
  ..addOval(
    Rect.fromCenter(
      center: const Offset(-0.17, 0.3),
      width: 0.42,
      height: 0.3,
    ),
  )
  ..addRect(const Rect.fromLTWH(0.0, -0.62, 0.065, 0.95))
  ..moveTo(0.065, -0.62)
  ..quadraticBezierTo(0.42, -0.44, 0.3, -0.06)
  ..quadraticBezierTo(0.36, -0.38, 0.065, -0.42)
  ..close();

/// Dos corcheas unidas por la barra.
final Path _beamedNotesPath = Path()
  ..addOval(
    Rect.fromCenter(
      center: const Offset(-0.35, 0.3),
      width: 0.38,
      height: 0.28,
    ),
  )
  ..addOval(
    Rect.fromCenter(
      center: const Offset(0.28, 0.14),
      width: 0.38,
      height: 0.28,
    ),
  )
  ..addRect(const Rect.fromLTWH(-0.19, -0.6, 0.06, 0.92))
  ..addRect(const Rect.fromLTWH(0.44, -0.6, 0.06, 0.76))
  ..addRect(const Rect.fromLTWH(-0.19, -0.6, 0.69, 0.16));

Path _triangle(Offset c, double s) => Path()
  ..addPolygon([
    Offset(c.dx - s * 0.6, c.dy - s * 0.5),
    Offset(c.dx + s * 0.6, c.dy - s * 0.5),
    Offset(c.dx, c.dy + s * 0.5),
  ], true);

Path _star(Offset c, double r) {
  final path = Path();
  const points = 4;
  for (var i = 0; i < points * 2; i++) {
    final angle = i * math.pi / points - math.pi / 2;
    final radius = i.isEven ? r : r * 0.26;
    final p = Offset(
      c.dx + math.cos(angle) * radius,
      c.dy + math.sin(angle) * radius,
    );
    if (i == 0) {
      path.moveTo(p.dx, p.dy);
    } else {
      path.lineTo(p.dx, p.dy);
    }
  }
  return path..close();
}

Path _crown(Offset c, double w) {
  final h = w * 0.72;
  return Path()
    ..moveTo(c.dx - w / 2, c.dy)
    ..lineTo(c.dx - w / 2, c.dy - h * 0.6)
    ..lineTo(c.dx - w * 0.25, c.dy - h * 0.25)
    ..lineTo(c.dx, c.dy - h)
    ..lineTo(c.dx + w * 0.25, c.dy - h * 0.25)
    ..lineTo(c.dx + w / 2, c.dy - h * 0.6)
    ..lineTo(c.dx + w / 2, c.dy)
    ..close();
}

const _xmasColors = [
  Color(0xFFFF5C5C),
  Color(0xFFFFD36E),
  Color(0xFF6BD08A),
  Color(0xFF6EC1FF),
];

const _partyColors = [
  Color(0xFFFFD36E),
  Color(0xFFFF7BA8),
  Color(0xFF7BE0FF),
  Color(0xFFB08BFF),
];

const _crownColors = [
  Color(0xFFFFD36E),
  Color(0xFFD7DCE5),
  Color(0xFFD98A5A),
];

const _loveColors = [
  Color(0xFFFF5C8A),
  Color(0xFFFF8FB1),
  Color(0xFFE0557A),
  Color(0xFFFFC2D4),
];

const _musicColors = [
  Color(0xFF7BE0FF),
  Color(0xFFB08BFF),
  Color(0xFF6BD08A),
  Color(0xFFFFD36E),
];
