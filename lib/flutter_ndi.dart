import 'dart:async';

import 'package:flutter/services.dart';

import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'dart:isolate';

import 'dart:io';

import 'libndi_bindings.dart';

final DynamicLibrary libNDI_dynamicLib = Platform.isAndroid
    ? DynamicLibrary.open("libndi.so")
    : DynamicLibrary.process();

NativeLibrary libNDI = new NativeLibrary(libNDI_dynamicLib);

class NDISource {
  String name;
  String address;

  NDISource({required this.name, required this.address});
}

abstract class FlutterNdi {
  static bool isLoaded = false;

  static const MethodChannel _channel = const MethodChannel('flutter_ndi');

  // TODO: Remove
  static Future<String?> get platformVersion async {
    // instance = libNDI.NDIlib_send_create();
    // if (!instance) {
    //   error
    // }

    // onframe
    // libNDI.NDIlib_send_send_video_v2(instance, p_video_data)

    final String? version = await _channel.invokeMethod('getPlatformVersion');
    return version;
  }

  static Future<bool> initPlugin() async {
    if (isLoaded) return isLoaded;
    // await _channel.invokeMethod('init_os');
    // libNDI = new NativeLibrary(libNDI_dynamicLib);
    if (libNDI.NDIlib_initialize()) return true;
    if (!libNDI.NDIlib_is_supported_CPU()) {
      throw Exception("CPU incompatible with NDI");
    } else {
      throw Exception("Unable to initialise NDI");
    }
  }

  static Pointer<Void> createSendHandle(String sourceName) {
    final source_data = calloc<NDIlib_send_create_t>();
    source_data.ref.p_ndi_name = sourceName.toNativeUtf8().cast<Int8>();

    return libNDI.NDIlib_send_create(source_data);
  }

  static Pointer<Void> createSourceFinder() {
    final finder_data = calloc<NDIlib_find_create_t>();
    finder_data.ref.show_local_sources = true_1;
    return libNDI.NDIlib_find_create_v2(finder_data);
  }

  static List<NDISource> findSources() =>
      findSourcesExplicit(createSourceFinder());
  static List<NDISource> findSourcesExplicit(Pointer<Void> SourceFinder) {
    List<NDISource> result = [];
    if (libNDI.NDIlib_find_wait_for_sources(SourceFinder, 5000)) {
      Pointer<Uint32> numSources = malloc<Uint32>();
      Pointer<NDIlib_source_t> sources =
          libNDI.NDIlib_find_get_current_sources(SourceFinder, numSources);
      for (var i = 0; i < numSources.value; i++) {
        NDIlib_source_t source_t = sources.elementAt(i).ref;
        result.add(NDISource(
            name: source_t.p_ndi_name.cast<Utf8>().toDartString(),
            address: source_t.p_url_address.cast<Utf8>().toDartString()));
      }
    }

    return result;
  }

  static ReceivePort listenToFrameData(NDISource source) {
    // FlutterNdi.libNDI.NDIlib_recv_create_v3()
    var source_t = malloc<NDIlib_source_t>();

    source_t.ref.p_ndi_name = source.name.toNativeUtf8().cast<Int8>();
    source_t.ref.p_url_address = source.address.toNativeUtf8().cast<Int8>();

    var recvDescription = malloc<NDIlib_recv_create_v3_t>();
    recvDescription.ref.source_to_connect_to = source_t.ref;
    recvDescription.ref.color_format =
        NDIlib_recv_color_format_e.NDIlib_recv_color_format_BGRX_BGRA;
    recvDescription.ref.bandwidth =
        NDIlib_recv_bandwidth_e.NDIlib_recv_bandwidth_highest;
    recvDescription.ref.allow_video_fields = false_1;
    recvDescription.ref.p_ndi_recv_name =
        "Channel 1".toNativeUtf8().cast<Int8>();

    Pointer<Void> Receiver = libNDI.NDIlib_recv_create_v3(recvDescription);

    ReceivePort _receivePort = new ReceivePort();

    Isolate.spawn(_receiverThread, {
      'port': _receivePort.sendPort,
      'receiver': Receiver.address,
    });
    // Isolate.spawn(_receiverThread, {'port': broadcaster});
    return _receivePort;
  }

  // Isolate _videoFrameReceiver;
  // final receivePort = ReceivePort();
  //https://gist.github.com/jebright/a7086adc305615aa3a655c6d8bd90264
  //http://a5.ua/blog/how-use-isolates-flutter
  // https://api.flutter.dev/flutter/dart-isolate/Isolate-class.html

  static void _receiverThread(Map map) {
    Pointer<Void> Receiver = Pointer<Void>.fromAddress(map['receiver']);
    SendPort emitter = map['port'];

    var vFrame = malloc<NDIlib_video_frame_v2_t>();
    var aFrame = malloc<NDIlib_audio_frame_v2_t>();
    var mFrame = malloc<NDIlib_metadata_frame_t>();

    while (true) {
      switch (libNDI.NDIlib_recv_capture_v2(
          Receiver, vFrame, aFrame, mFrame, 1000)) {
        case NDIlib_frame_type_e.NDIlib_frame_type_none:
          break;
        case NDIlib_frame_type_e.NDIlib_frame_type_video:
          int yres = vFrame.ref.yres;
          int xres = vFrame.ref.xres;
          double dpi = 96.0 * vFrame.ref.picture_aspect_ratio / (xres / yres);
          int stride =
              vFrame.ref.data_size_if_fourcc_compressed_else_line_stride;
          // Stride = bytes per line
          // Should be 4 * width -- BGRA
          emitter.send({
            'width': xres,
            'height': yres,
            'data': vFrame.ref.p_data.asTypedList(yres * stride)
          });

          ///
          libNDI.NDIlib_recv_free_video_v2(Receiver, vFrame);
          break;
        case NDIlib_frame_type_e.NDIlib_frame_type_audio:
          libNDI.NDIlib_recv_free_audio_v2(Receiver, aFrame);
          break;
        case NDIlib_frame_type_e.NDIlib_frame_type_metadata:
          libNDI.NDIlib_recv_free_metadata(Receiver, mFrame);
          break;
        case NDIlib_frame_type_e.NDIlib_frame_type_error:
          break;
        case NDIlib_frame_type_e.NDIlib_frame_type_status_change:
          break;
      }
    }
  }
}
