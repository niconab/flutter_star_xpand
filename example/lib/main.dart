import 'package:flutter/material.dart';
import 'package:flutter_star_prnt_plus/flutter_star_prnt.dart';

void main() => runApp(const MaterialApp(home: ExamplePage()));

class ExamplePage extends StatefulWidget {
  const ExamplePage({super.key});
  @override
  State<ExamplePage> createState() => _ExamplePageState();
}

class _ExamplePageState extends State<ExamplePage> {
  List<PortInfo> _ports = [];
  String _log = '';
  bool _busy = false;

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      setState(() => _log = 'Error: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _discover() => _run(() async {
        final ports = await StarPrnt.portDiscovery(StarPortType.All);
        setState(() {
          _ports = ports;
          _log = 'Found ${ports.length} printer(s)';
        });
      });

  Future<void> _status(PortInfo p) => _run(() async {
        final s = await StarPrnt.getStatus(
            portName: p.portName!, emulation: _emulation(p));
        setState(() => _log = s.toString());
      });

  String _emulation(PortInfo p) =>
      StarMicronicsUtilities.detectEmulation(modelName: p.modelName)
          ?.emulation ??
      'StarPRNT';

  Future<void> _print(PortInfo p) => _run(() async {
        final c = PrintCommands();
        c.appendEncoding(StarEncoding.UTF8);
        c.push({'appendAlignment': 'Center', 'data': 'Telme\n'});
        c.push({'append': 'Hej från StarXpand! åäö ÅÄÖ\n'});
        c.appendBitmapText(text: 'Bitmap-text\n12 st  Kaffe   49,00 kr');
        c.push({'appendBarcode': '1234567890', 'BarcodeSymbology': 'Code128'});
        c.appendCutPaper(StarCutPaperAction.PartialCutWithFeed);
        final r = await StarPrnt.sendCommands(
            portName: p.portName!, emulation: _emulation(p), printCommands: c);
        setState(() => _log = r.toString());
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('flutter_star_xpand example')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: ElevatedButton(
              onPressed: _busy ? null : _discover,
              child: Text(_busy ? 'Working…' : 'Discover printers')),
        ),
        Expanded(
          child: ListView(
            children: _ports
                .map((p) => ListTile(
                      title: Text(p.modelName ?? '?'),
                      subtitle: Text(p.portName ?? ''),
                      trailing: Wrap(children: [
                        IconButton(
                            icon: const Icon(Icons.info_outline),
                            onPressed: _busy ? null : () => _status(p)),
                        IconButton(
                            icon: const Icon(Icons.print),
                            onPressed: _busy ? null : () => _print(p)),
                      ]),
                    ))
                .toList(),
          ),
        ),
        Padding(padding: const EdgeInsets.all(8), child: Text(_log)),
      ]),
    );
  }
}
