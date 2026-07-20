package __PACKAGE__

// CarMediaListenerService.kt
//
// Servico de "acesso a notificacoes" (NotificationListenerService) usado
// SO para ler METADADOS de sessoes de midia ativas (titulo/artista/estado
// tocando-pausado) de outros apps, como o Spotify. Isso e o mesmo mecanismo
// que qualquer widget "Now Playing" do Android usa.
//
// Nao lemos o conteudo de notificacoes (onNotificationPosted fica vazio de
// proposito) - so usamos o MediaSessionManager, que e uma API separada que
// fica disponivel para o app assim que o usuario concede "Acesso a
// notificacoes" nas configuracoes do sistema (Configuracoes -> Apps ->
// Acesso especial -> Acesso a notificacoes). Nao existe um popup automatico
// de permissao para isso; o usuario precisa habilitar manualmente, por isso
// a tela de Configuracoes do launcher tem um botao que abre essa tela
// direto (via MainActivity.openNotificationSettings).

import android.content.ComponentName
import android.content.Intent
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

class CarMediaListenerService : NotificationListenerService() {

    private var sessionManager: MediaSessionManager? = null

    private val sessionListener =
        MediaSessionManager.OnActiveSessionsChangedListener { controllers ->
            publishFromControllers(controllers)
        }

    override fun onListenerConnected() {
        super.onListenerConnected()
        try {
            sessionManager = getSystemService(MEDIA_SESSION_SERVICE) as MediaSessionManager
            val component = ComponentName(this, CarMediaListenerService::class.java)
            sessionManager?.addOnActiveSessionsChangedListener(sessionListener, component)
            publishFromControllers(sessionManager?.getActiveSessions(component))
        } catch (e: SecurityException) {
            // Acesso a notificacoes ainda nao concedido pelo usuario nas
            // configuracoes do sistema - nada a fazer alem de aguardar.
        }
    }

    override fun onListenerDisconnected() {
        try {
            sessionManager?.removeOnActiveSessionsChangedListener(sessionListener)
        } catch (e: Exception) {
            // Servico ja estava desconectado - sem problema.
        }
        super.onListenerDisconnected()
    }

    private fun publishFromControllers(controllers: List<MediaController>?) {
        val playing = controllers?.firstOrNull {
            it.playbackState?.state == PlaybackState.STATE_PLAYING
        } ?: controllers?.firstOrNull()

        val intent = Intent("com.neoncar.launcher.MEDIA_CHANGED")
        intent.setPackage(packageName)
        if (playing != null) {
            val meta = playing.metadata
            intent.putExtra("title", meta?.getString(MediaMetadata.METADATA_KEY_TITLE))
            intent.putExtra("artist", meta?.getString(MediaMetadata.METADATA_KEY_ARTIST))
            intent.putExtra(
                "isPlaying",
                playing.playbackState?.state == PlaybackState.STATE_PLAYING
            )
        } else {
            intent.putExtra("title", null as String?)
            intent.putExtra("artist", null as String?)
            intent.putExtra("isPlaying", false)
        }
        sendBroadcast(intent)
    }

    // Nao processamos notificacoes individuais - so sessoes de midia acima.
    override fun onNotificationPosted(sbn: StatusBarNotification?) {}

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {}
}
