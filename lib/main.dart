import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/platform_tags.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'Flutter NFC app'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  ValueNotifier<dynamic> result = ValueNotifier(null);
  bool isAvailable = false;
  late String token;

  String _byteArrayToHexString(List<int> byteArray) {
    final hexList = byteArray.map((byte) {
      final hex = byte.toRadixString(16).toUpperCase();
      return hex.length == 1 ? '0$hex' : hex;
    }).toList();

    return hexList.join();
  }

  Uint8List _hexStringToByteArray(String hexString) {
    final byteArray = <int>[];

    for (int i = 0; i < hexString.length; i += 2) {
      final byte = int.parse(hexString.substring(i, i + 2), radix: 16);
      byteArray.add(byte);
    }

    return Uint8List.fromList(byteArray);
  }

  Future<void> _getToken() async {
    try {
      final Uri loginUri = Uri.parse(
          'https://card-city.tapandgoticketing.co.rw/api/v1/operators/login');

      final response = await http.post(loginUri,
          headers: {
            'Content-Type': 'application/json',
          },
          body: jsonEncode(
              {'username': 'support@acgroup.rw', 'password': 'Kigali@123'}));
      final statusCode = response.statusCode;
      final loginResponse = json.decode(response.body);
      print('status-code $statusCode');
      print('statusBody $loginResponse');
      setState(() {
        token = loginResponse['data']['token'];
      });
    } catch (e) {
      // handling errors here
      print('error=> ${e.toString()}');
    }
  }

  Future<void> _startSession() async {
    if (await NfcManager.instance.isAvailable()) {
      setState(() {
        isAvailable = true;
      });
      NfcManager.instance.startSession(
        onDiscovered: (NfcTag tag) async {
          try {
            String authenticationKey = '';
            result.value = tag.data;
            print("discoveredTag $tag");
            print(result);
            final tech = MifareClassic.from(tag);
            final cardId = _byteArrayToHexString(tech!.identifier);
            print("==cardId==>$cardId");

            final Uri sesscionUri = Uri.parse(
                'https://card-city.tapandgoticketing.co.rw/api/v1/card-pay');

            final response = await http.post(sesscionUri,
                headers: {
                  'Content-Type': 'application/json',
                  'x-auth': token,
                },
                body: jsonEncode({'card_number': cardId}));

            final statusCode = response.statusCode;
            final sessionResponse = json.decode(response.body);

            print('sessionRespnse==> $sessionResponse');

            //       const sectors =
            //   sessionData.data.data.session_data.content.command.authInfo.sectors;
            // const clientSessionId =
            //   sessionData.data.data.session_data.header.clientSessionId;
            // const serverSessionId =
            //   sessionData.data.data.session_data.header.serverSessionId;
            // console.log({sectors, clientSessionId, serverSessionId});

            final sectors = sessionResponse['data']['session_data']['content']
                ['command']['authInfo']['sectors'];
            final clientSessionId = sessionResponse['data']['session_data']
                ['header']['clientSessionId'];
            final serverSessionId = sessionResponse['data']['session_data']
                ['header']['serverSessionId'];
            print('===sectors==> $sectors');
            print("clientSessionId=> $clientSessionId");
            print("==serverSessionId==> $serverSessionId");

            final mifareClassic = MifareClassic(
                tag: tag,
                identifier: tech.identifier,
                type: tech.type,
                blockCount: tech.blockCount,
                sectorCount: tech.sectorCount,
                size: tech.size,
                maxTransceiveLength: tech.maxTransceiveLength,
                timeout: tech.timeout);

            List command = [];
            for (final sec in sectors) {
              print("==single sector==> $sec");

              print("===reaching here===>");
              authenticationKey = sec['key'];
              final Uint8List authKey = _hexStringToByteArray(sec['key']);
              final bool authenticated =
                  await mifareClassic.authenticateSectorWithKeyB(
                      sectorIndex: sec['no'], key: authKey);

              final blockCount = await mifareClassic.getBlockCountInSector(
                  sectorIndex: sec['no']);

              List blocks = [];

              for (var i = 0; i < 3; i++) {
                final bIndex =
                    await mifareClassic.sectorToBlock(sectorIndex: sec['no']);

                final Uint8List blockData =
                    await mifareClassic.readBlock(blockIndex: bIndex + i);
                final String blockParsedData = _byteArrayToHexString(blockData);
                final Map block = {'no': i, 'data': blockParsedData};
                blocks.add(block);
              }
              Map blockCommand = {'no': sec['no'], 'blocks': blocks};
              command.add(blockCommand);
            }

            Map payPayload = {
              'amount': 0,
              'card_number': cardId,
              'session_data': {
                'header': {
                  'versionSchema': 1,
                  'clientSessionId': clientSessionId,
                  'serverSessionId': serverSessionId
                }
              },
              'card_command': {'sectors': command}
            };

            final Uri payUri = Uri.parse(
                'https://card-city.tapandgoticketing.co.rw/api/v1/card-pay-complete');

            final payResponse = await http.post(payUri,
                headers: {
                  'Content-Type': 'application/json',
                  'x-auth': token,
                },
                body: jsonEncode(payPayload));

            final payStatusCode = payResponse.statusCode;
            final payResponseData = json.decode(payResponse.body);

            print('==pay-complete-statusCode $payStatusCode');
            print('==pay-complete-reponse==> $payResponseData');

            final sectorsToWrite =
                payResponseData['data']['card_content']['command']['sectors'];
            print('==sectorsToWrite==> $sectorsToWrite');

            // mifareClassic.setTimeout()

            for (final sec in sectorsToWrite) {
              print('---getting here---> ${sec['no']}');
              print('---getting-------+>${sec['blocks']}');
              // final Uint8List authKey = _hexStringToByteArray(sec['key']);
              // final bool authenticated =
              //     await mifareClassic.authenticateSectorWithKeyB(
              //         sectorIndex: sec['no'], key: authKey);
              // print("--authenticated-->, $authenticated");
              print('===getting-length==>${sec['blocks'].length}');

              for (int i = 0; i < sec['blocks'].length; i++) {
                print('--getting-data-write-->');
                int bIndex =
                    await mifareClassic.sectorToBlock(sectorIndex: sec['no']);
                Uint8List bytesData =
                    _hexStringToByteArray(sec['blocks'][i]['data']);
                print("===authKeys==>$authenticationKey");
                final Uint8List authKey =
                    _hexStringToByteArray(authenticationKey);
                final bool authenticated =
                    await mifareClassic.authenticateSectorWithKeyB(
                        sectorIndex: sec['no'], key: authKey);
                print("===authenticated-to-write===>$authenticated");
                await mifareClassic.writeBlock(
                    blockIndex: bIndex + i, data: bytesData);
              }
            }

            print("==Now is done===>");

            if (result == null) return;
            await NfcManager.instance.stopSession();
            // _startSession();
            // setState(() => _alertMessage = result);
          } catch (e) {
            await NfcManager.instance
                .stopSession()
                .catchError((_) {/* no op */});
            print("startSessionError ${e.toString()}");
            // setState(() => _errorMessage = '$e');
          }
        },
      ).catchError((e) => {print("commonError ${e.toString()}")});
    }
  }

  @override
  void initState() {
    super.initState();
    _getToken();
    _startSession();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: isAvailable
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Text(
                    'This is my nfc app',
                  ),
                  // Text(
                  //   '$_counter',
                  //   style: Theme.of(context).textTheme.headlineMedium,
                  // ),
                ],
              ),
            )
          : const Center(
              child: Text("Nfc not supported"),
            ),
    );
  }
}
