package __PACKAGE__

// MainActivity.kt
//
// Substitui o MainActivity.kt padrão gerado pelo `flutter create`. Adiciona
// dois canais nativos que não têm pacote Flutter pronto no pub.dev:
//
// 1. "com.neoncar.launcher/telecom" — atender/encerrar chamada usando
//    TelecomManager. Isso funciona em apps comuns (não precisa ser o
//    discador padrão) desde a permissão ANSWER_PHONE_CALLS (Android 8+).
//
// 2. "com.neoncar.launcher/reverse" — registra dinamicamente um
//    BroadcastReceiver para a ação (string) que a central multimídia usa
//    para sinalizar marcha-ré. Essa ação VARIA por fabricante da central
//    (Carlinkit, Ottocast, MCU genérico, etc.) — não existe um padrão
//    universal. Configure a ação certa em Configurações → Câmera de ré,
//    consultando a documentação/suporte da sua central.
//
// IMPORTANTE: em muitas centrais automotivas baratas, a troca para a câmera
// de ré é feita por hardware (o próprio fio de ré aciona a chave de vídeo
// direto, sem passar pelo Android) — nesse caso, nenhum código aqui é
// necessário, a central já troca sozinha. Este canal só é útil se a SUA
// central específica expõe esse evento como um broadcast Android.

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.telecom.TelecomManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val telecomChannelName = "com.neoncar.launcher/telecom"
    private val reverseChannelName = "com.neoncar.launcher/reverse"

    private var reverseChannel: MethodChannel? = null
    private var reverseReceiver: BroadcastReceiver? = null
    private var registeredAction: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, telecomChannelName)
            .setMethodCallHandler { call, result ->
                val telecomManager =
                    getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
                try {
                    when (call.method) {
                        "answerCall" -> {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                telecomManager?.acceptRingingCall()
                                result.success(true)
                            } else {
                                result.error("UNSUPPORTED", "Requer Android 8.0+", null)
                            }
                        }
                        "endCall" -> {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                                val ended = telecomManager?.endCall() ?: false
                                result.success(ended)
                            } else {
                                result.error("UNSUPPORTED", "Requer Android 9.0+", null)
                            }
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: SecurityException) {
                    // Permissão ANSWER_PHONE_CALLS não concedida pelo usuário ainda.
                    result.error("NO_PERMISSION", e.message, null)
                }
            }

        reverseChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, reverseChannelName)
        reverseChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "register" -> {
                    val action = call.argument<String>("action")
                    if (action.isNullOrBlank()) {
                        result.error("INVALID_ACTION", "Ação de broadcast vazia", null)
                        return@setMethodCallHandler
                    }
                    unregisterReverseReceiver()
                    registeredAction = action
                    reverseReceiver = object : BroadcastReceiver() {
                        override fun onReceive(context: Context?, intent: Intent?) {
                            reverseChannel?.invokeMethod("onReverseTriggered", null)
                        }
                    }
                    registerReceiver(reverseReceiver, IntentFilter(action))
                    result.success(true)
                }
                "unregister" -> {
                    unregisterReverseReceiver()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun unregisterReverseReceiver() {
        reverseReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (e: IllegalArgumentException) {
                // já estava desregistrado — sem problema.
            }
        }
        reverseReceiver = null
    }

    override fun onDestroy() {
        unregisterReverseReceiver()
        super.onDestroy()
    }
}
