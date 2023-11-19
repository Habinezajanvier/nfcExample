import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    return const MaterialApp(
      title: 'Flutter Demo',
      debugShowCheckedModeBanner: false,
      // theme: ThemeData(
      //   // colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      //   useMaterial3: true,
      // ),
      home: MyHomePage(title: 'Flutter NFC app'),
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
  String initialWord = "Device is ready, tap your card";
  Color light = const Color.fromARGB(255, 255, 255, 255);
  String? startingTime;
  String? endTime;
  String? previousBalance;
  String? currentBalance;
  String? cardNumber;
  // String baseUrl = "https://b5c7-105-178-104-197.ngrok-free.app";
  // String baseUrl = "https://card-city.tapandgoticketing.co.rw";
  String baseUrl = "https://interoperability.tapandgoticketing.co.rw";
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
      final Uri loginUri = Uri.parse('$baseUrl/api/v1/operators/login');

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
            DateTime now = DateTime.now();
            setState(() {
              startingTime =
                  "Start time: ${now.toLocal().toLocal().toString()}";
              initialWord = "Hold your card on device";
              light = Colors.yellow;
            });
            print("=====>$startingTime");
            String authenticationKey = '';
            result.value = tag.data;
            print("discoveredTag $tag");
            print(result);
            MifareClassic? tech = MifareClassic.from(tag);
            String cardId = _byteArrayToHexString(tech!.identifier);
            print("==cardId==>$cardId");
            setState(() {
              cardNumber = cardId;
            });

            DateTime firstApiCall = DateTime.now();
            print(
                '==sending-first-api==> ${firstApiCall.toLocal().toLocal().toString()}');

            final Uri sesscionUri = Uri.parse('$baseUrl/api/v1/card-pay');
            print('Start-session-url===> $sesscionUri');

            final response = await http.post(sesscionUri,
                headers: {
                  'Content-Type': 'application/json',
                  'x-auth': token,
                },
                body: jsonEncode({'card_number': cardId, 'amount': 2500}));

            final statusCode = response.statusCode;
            final sessionResponse = json.decode(response.body);

            print("===this is the response===>$sessionResponse");

            final sectors = sessionResponse['data']['session_data']['content']
                ['command']['authInfo']['sectors'];
            final clientSessionId = sessionResponse['data']['session_data']
                ['header']['clientSessionId'];
            final serverSessionId = sessionResponse['data']['session_data']
                ['header']['serverSessionId'];
            // print('===sectors==> $sectors');
            // print("clientSessionId=> $clientSessionId");
            // print("==serverSessionId==> $serverSessionId");

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
            DateTime endOfSession = DateTime.now();
            print(
                '==starting to read==> ${endOfSession.toLocal().toLocal().toString()}');
            for (final sec in sectors) {
              // print("==single sector==> $sec");

              // print("===reaching here===>");
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

            print('---command--->$command');

            Map payPayload = {
              'amount': 2500,
              'operatorCompany': 'EWAKA',
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

            final Uri payUri = Uri.parse('$baseUrl/api/v1/ewaka-pay-complete');
            print("==pay-complete-uri==>$payUri");
            DateTime startingPayment = DateTime.now();
            print(
                '==Sending the request==> ${startingPayment.toLocal().toLocal().toString()}');

            final payResponse = await http.post(payUri,
                headers: {
                  'Content-Type': 'application/json',
                  'x-auth': token,
                },
                body: jsonEncode(payPayload));

            final payStatusCode = payResponse.statusCode;
            final payResponseData = json.decode(payResponse.body);

            DateTime endOfPayment = DateTime.now();
            print(
                '==Getting-payment-response==> ${endOfPayment.toLocal().toLocal().toString()}');

            print('==pay-complete-statusCode ${payResponseData['message']}');
            print('==pay-complete-statusCode $payStatusCode');
            // print(
            //     '==previous-balance==>${payResponseData['data']['card_content']['previousBalance']}');
            // print(
            //     '==previous-balance==>${payResponseData['data']['card_content']['currentBalance']}');
            if (payStatusCode != 200) {
              await NfcManager.instance.stopSession();
              setState(() {
                initialWord = payResponseData['message'];
                endTime =
                    "End time: ${endOfPayment.toLocal().toLocal().toString()}";
                light = Colors.red;
              });
              Future.delayed(const Duration(seconds: 4), () {
                setState(() {
                  initialWord = "Device is ready, tap your card";
                  light = const Color.fromARGB(255, 255, 255, 255);
                  cardNumber = null;
                  startingTime = null;
                  endTime = null;
                  previousBalance = null;
                  currentBalance = null;
                });
                _startSession();
              });
            } else {
              setState(() {
                previousBalance =
                    "Previous Balance: ${payResponseData['data']['card_content']['previousBalance']}";
                currentBalance =
                    "Current Balance: ${payResponseData['data']['card_content']['currentBalance']}";
              });

              final sectorsToWrite =
                  payResponseData['data']['card_content']['command']['sectors'];
              // print('==sectorsToWrite==> $sectorsToWrite');

              // mifareClassic.setTimeout()

              print('==sectorsToWrite==>$sectorsToWrite');
              for (final sec in sectorsToWrite) {
                // print('---getting here---> ${sec['no']}');
                // print('---getting-------+>${sec['blocks']}');
                // final Uint8List authKey = _hexStringToByteArray(sec['key']);
                // final bool authenticated =
                //     await mifareClassic.authenticateSectorWithKeyB(
                //         sectorIndex: sec['no'], key: authKey);
                // print("--authenticated-->, $authenticated");
                // print('===getting-length==>${sec['blocks'].length}');

                for (int i = 0; i < sec['blocks'].length; i++) {
                  // print('--getting-data-write-->');
                  int bIndex =
                      await mifareClassic.sectorToBlock(sectorIndex: sec['no']);
                  Uint8List bytesData =
                      _hexStringToByteArray(sec['blocks'][i]['data']);
                  // print("===authKeys==>$authenticationKey");
                  final Uint8List authKey =
                      _hexStringToByteArray(authenticationKey);
                  final bool authenticated =
                      await mifareClassic.authenticateSectorWithKeyB(
                          sectorIndex: sec['no'], key: authKey);
                  print("===authenticated-to-write===>$authenticated");
                  print("==blockToWrite==>${bIndex + i}");
                  await mifareClassic.writeBlock(
                      blockIndex: bIndex + i, data: bytesData);
                }
              }

              DateTime endedTime = DateTime.now();
              setState(() {
                initialWord = "You can remove your card";
                endTime =
                    "End time: ${endedTime.toLocal().toLocal().toString()}";
                light = Colors.green;
              });
              print(endTime);

              Future.delayed(const Duration(seconds: 4), () {
                setState(() {
                  initialWord = "Device is ready, tap your card";
                  light = const Color.fromARGB(255, 255, 255, 255);
                  cardNumber = null;
                  startingTime = null;
                  endTime = null;
                  previousBalance = null;
                  currentBalance = null;
                });
                _startSession();
              });

              print("==Now is done===>");

              if (result == null) return;
              await NfcManager.instance.stopSession();
              // _startSession();
              // setState(() => _alertMessage = result);
            }
          } catch (e) {
            await NfcManager.instance
                .stopSession()
                .catchError((_) {/* no op */});
            DateTime endedTime = DateTime.now();
            setState(() {
              initialWord = "Error occored";
              endTime = "End time: ${endedTime.toLocal().toLocal().toString()}";
              light = Colors.red;
            });
            Future.delayed(const Duration(seconds: 4), () {
              setState(() {
                initialWord = "Device is ready, tap your card";
                light = const Color.fromARGB(255, 255, 255, 255);
                cardNumber = null;
                startingTime = null;
                endTime = null;
                previousBalance = null;
                currentBalance = null;
              });
              _startSession();
            });
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
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: [SystemUiOverlay.bottom]);
    _getToken();
    _startSession();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: isAvailable
          ? Center(
              child: Container(
                width: MediaQuery.of(context).size.width * 0.9,
                margin: const EdgeInsets.symmetric(vertical: 20.0),
                padding: const EdgeInsets.symmetric(vertical: 20),
                decoration: BoxDecoration(
                    color: const Color.fromARGB(158, 101, 184, 216),
                    border: Border.all(width: 2.0, color: Colors.blue),
                    borderRadius:
                        const BorderRadius.all(Radius.circular(12.0))),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        const Text(
                          "PAY WITH YOUR TAB&GO CARD",
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 18,
                              color: Color.fromARGB(255, 2, 8, 118)),
                        ),
                        const SizedBox(
                          height: 12,
                        ),
                        Text(
                          cardNumber ?? "",
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 18),
                        ),
                        const SizedBox(
                          height: 12,
                        ),
                        Text(
                          initialWord,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 18),
                        ),
                        const SizedBox(
                          height: 12,
                        ),
                        Text(
                          startingTime ?? "",
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          endTime ?? "",
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(
                          height: 24,
                        ),
                        // Text(
                        //   previousBalance ?? "",
                        //   style: const TextStyle(fontWeight: FontWeight.w400),
                        // ),
                        Text(
                          currentBalance ?? "",
                          style: const TextStyle(
                              fontWeight: FontWeight.w400, fontSize: 17),
                        ),
                      ],
                    ),
                    SizedBox(
                      height: 40,
                      child: Center(
                        child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            shrinkWrap: true,
                            itemCount: 4,
                            itemBuilder: (context, index) {
                              return Container(
                                width: 30,
                                height: 30,
                                margin: const EdgeInsets.all(4.0),
                                decoration: BoxDecoration(
                                    color: light,
                                    border: Border.all(
                                        color: Colors.blue, width: 1),
                                    borderRadius: const BorderRadius.all(
                                        Radius.circular(10.0))),
                              );
                            }),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : const Center(
              child: Text("Nfc not supported"),
            ),
    );
  }
}
