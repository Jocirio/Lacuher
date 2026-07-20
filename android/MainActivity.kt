package __PACKAGE__

// MainActivity.kt
//
// Substitui o MainActivity.kt padrão gerado pelo `flutter create`. Adiciona
// três canais nativos que não têm pacote Flutter pronto no pub.dev:
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
//
// 3. "com.neoncar.launcher/media" — recebe (via broadcast local) os
//    metadados de mídia publicados pelo CarMediaListenerService.kt (título/
//    artista/estado tocando-pausado da sessão ativa, ex: Spotify) e repassa
//    para o Flutter. Também expõe "openNotificationSettings" para abrir a
//    tela do sistema onde o usuário concede "Acesso a notificações".

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.provider.Settings
import android.telecom.TelecomManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val telecomChannelName = "com.neoncar.launcher/telecom"
    private val reverseChannelName = "com.neoncar.launcher/reverse"
    private val mediaChannelName = "com.neoncar.launcher/media"

    private var reverseChannel: MethodChannel? = null
    private var reverseReceiver: BroadcastReceiver? = null
    private var registeredAction: String? = null

    private var mediaChannel: MethodChannel? = null
    private var mediaReceiver: BroadcastReceiver? = null

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
                    registerAppReceiver(reverseReceiver, IntentFilter(action))
                    result.success(true)
                }
                "unregister" -> {
                    unregisterReverseReceiver()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        mediaChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, mediaChannelName)
        mediaChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestCurrent" -> {
                    // O CarMediaListenerService reenvia o estado atual sozinho
                    // quando se conecta (onListenerConnected); aqui só
                    // confirmamos que o canal está pronto.
                    result.success(true)
                }
                "openNotificationSettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("CANNOT_OPEN", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        mediaReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                val map = HashMap<String, Any?>()
                map["title"] = intent?.getStringExtra("title")
                map["artist"] = intent?.getStringExtra("artist")
                map["isPlaying"] = intent?.getBooleanExtra("isPlaying", false) ?: false
                mediaChannel?.invokeMethod("onMediaChanged", map)
            }
        }
        registerAppReceiver(mediaReceiver, IntentFilter("com.neoncar.launcher.MEDIA_CHANGED"))
    }

    /// Registra um BroadcastReceiver interno ao app. A partir do Android 13
    /// (API 33) é obrigatório declarar explicitamente se o receiver pode
    /// receber broadcasts de outros apps (EXPORTED) ou só do próprio app
    /// (NOT_EXPORTED) — usamos NOT_EXPORTED pois esses broadcasts são só
    /// para comunicação interna do launcher.
    private fun registerAppReceiver(receiver: BroadcastReceiver?, filter: IntentFilter) {
        if (receiver == null) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(receiver, filter)
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

    private fun unregisterMediaReceiver() {
        mediaReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (e: IllegalArgumentException) {
                // já estava desregistrado — sem problema.
            }
        }
        mediaReceiver = null
    }

    override fun onDestroy() {
        unregisterReverseReceiver()
        unregisterMediaReceiver()
        super.onDestroy()
    }
}
