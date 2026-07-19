# Neon Car Launcher

Iniciador (launcher) premium para multimídia automotiva Android — tema escuro com
neon selecionável (Roxo / Ciano / Esmeralda), velocímetro real via GPS, integração
com apps nativos (Waze, Google Maps, Spotify), mapa offline, computador de bordo,
leitor OBD-II via Bluetooth, chamadas viva-voz e câmera de ré configurável.

## As 4 funcionalidades novas — o que cada uma exige de verdade

Estas quatro dependem de hardware ou de configuração específica do seu carro/
central. Nenhuma delas foi testada num aparelho real (não tenho como compilar
nem rodar Flutter aqui), então trate como uma implementação de melhor esforço,
documentada com o máximo de honestidade sobre as suposições feitas:

1. **Computador de bordo** (distância/velocidade média/máxima da viagem) —
   funciona sozinho, só usa o GPS que já líamos. Sem dependências externas.

2. **Histórico de viagens** — banco local (SQLite via `sqflite`), nada sai do
   aparelho. Funciona sozinho também.

3. **OBD-II via Bluetooth** — exige um adaptador ELM327 (uns R$30-50,
   compatível com a porta OBD-II de carros pós-1996). Pareie o adaptador nas
   configurações de Bluetooth do Android da central primeiro, depois cole o
   endereço MAC dele em Configurações → OBD-II. O parsing dos dados (RPM,
   temperatura, combustível) segue o protocolo padrão OBD-II modo 01, mas
   cada ECU responde de um jeito — pode precisar de ajustes finos depois de
   testar no seu carro específico.

4. **Chamadas viva-voz sem CarPlay/Android Auto** — usa a permissão
   `ANSWER_PHONE_CALLS` (Android 8+) via `TelecomManager`, implementada em
   `android/MainActivity.kt`. Funciona com o celular só pareado por
   Bluetooth para chamadas (perfil HFP), sem precisar abrir um app espelhado.
   A API do pacote `phone_state` usada para detectar a chamada tocando pode
   variar entre versões — se o `flutter pub get` trazer uma versão com nomes
   de campo diferentes, ajuste `CallGuardService` em `lib/main.dart`.

5. **Câmera de ré** — **leia com atenção antes de configurar**: na maioria
   das centrais automotivas baratas, a troca para a câmera de ré acontece
   por hardware (o próprio fio de ré aciona a chave de vídeo direto, sem
   passar pelo Android) — nesse caso, **nada precisa ser configurado**, a
   central já troca sozinha. Só preencha o campo "Câmera de ré" em
   Configurações se a SUA central especificamente expõe esse evento como um
   broadcast Android — a ação exata varia por fabricante (Carlinkit,
   Ottocast, MCU genérico...) e você vai precisar descobrir qual é a sua,
   geralmente com o suporte/documentação de quem vendeu a central.

Se qualquer uma dessas quatro não funcionar exatamente como esperado no seu
carro, é porque depende de peças de hardware e variações de fabricante que
eu não tenho como testar remotamente — me diga o que aconteceu (mensagem de
erro, comportamento) que ajusto o código.

## Por que este README existe em dois caminhos

Tentei compilar o APK diretamente por você, mas o ambiente isolado onde eu rodo
comandos bloqueia o acesso aos servidores do Google/Flutter/Gradle (é uma restrição
de rede do próprio ambiente, não do projeto). Então, em vez de te devolver só o
código-fonte, montei o repositório para que o **próprio GitHub compile o APK
para você de graça**, sem precisar instalar Flutter, Android Studio ou nada no
seu computador. Esse é o **Caminho A** abaixo — é o recomendado.

Se preferir compilar na sua máquina (ou já tiver Flutter instalado), use o
**Caminho B**.

---

## Caminho A — Build automático na nuvem (sem instalar nada)

1. Crie uma conta gratuita em https://github.com (se ainda não tiver).
2. Crie um repositório novo (botão verde "New"), pode ser privado, com qualquer nome
   (ex: `neon-car-launcher`).
3. Na página do repositório, clique em "Add file" → "Upload files" e arraste
   **todo o conteúdo** desta pasta (`pubspec.yaml`, `lib/`, `AndroidManifest.xml`,
   `assets/`, `.github/`) mantendo a mesma estrutura de pastas. Confirme o commit.
4. Vá na aba **Actions** do repositório. Um workflow chamado
   "Build Neon Car Launcher APK" já deve estar rodando automaticamente
   (leva de 4 a 8 minutos).
5. Quando o círculo ficar verde (✓), clique no build concluído e desça até
   **Artifacts** → baixe `neon-car-launcher-apk.zip`.
6. Descompacte no seu computador. Dentro tem 3 APKs (um por arquitetura de
   processador). Para a imensa maioria das centrais multimídia (processador
   ARM), use o `app-arm64-v8a-release.apk` — é o mais leve.
7. Copie esse `.apk` para um pendrive (formatado em FAT32).
8. Na central multimídia: abra o gerenciador de arquivos, habilite "Fontes
   desconhecidas"/"Instalar apps de origem desconhecida" nas configurações,
   navegue até o pendrive e toque no `.apk` para instalar.
9. Pressione o botão físico "Home" do carro — o Android vai perguntar qual
   app usar como tela inicial. Escolha "Neon Car Launcher" e marque "Sempre".

Nenhum passo acima usa linha de comando — é tudo pelo navegador.

---

## Caminho B — Build local (se você já tem Flutter instalado)

```bash
flutter create --org com.neoncar neon_car_launcher
cd neon_car_launcher
cp /caminho/para/pubspec.yaml ./pubspec.yaml
cp /caminho/para/lib/main.dart ./lib/main.dart
cp /caminho/para/AndroidManifest.xml ./android/app/src/main/AndroidManifest.xml
rm -rf assets && cp -r /caminho/para/assets ./assets
flutter pub get
flutter build apk --release --split-per-abi
```

O APK final fica em `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`.

---

## Trocar/ampliar o mapa depois, sem recompilar (Mato Grosso e Mato Grosso do Sul agora, Brasil quando quiser)

O app agora suporta duas fontes de tiles:

1. **Tiles embutidos no APK** (`assets/map_tiles/`) — é o padrão, usado quando
   nenhuma pasta externa é configurada.
2. **Uma pasta externa num SD/pendrive** — configurável em
   **Configurações → Pasta de mapas offline**, direto no app, sem precisar
   recompilar nada.

Fluxo recomendado para você, que quer começar com Mato Grosso + Mato Grosso
do Sul e ampliar depois:

1. Gere os tiles de MT + MS no MOBAC (veja seção seguinte) e salve numa
   pasta, ex: `NeonMaps/` (estrutura `NeonMaps/{z}/{x}/{y}.png`).
2. Copie essa pasta `NeonMaps` para dentro de um pendrive ou do cartão SD
   da central.
3. No launcher, abra **Configurações → Pasta de mapas offline** e toque em
   **"Selecionar pasta"** (abre o seletor de pastas do Android) — ou, se o
   seletor automático não funcionar naquela central (algumas ROMs
   automotivas restringem isso), cole o caminho manualmente no campo de
   texto, algo como `/storage/6331-6162/NeonMaps` (pendrive/SD) ou
   `/storage/emulated/0/NeonMaps` (armazenamento interno) — e toque em
   "Salvar".
4. Pronto: o mapa passa a ler dessa pasta imediatamente, sem rebuild.
5. Quando quiser ampliar para o Brasil inteiro (ou qualquer outra área),
   basta gerar os novos tiles no MOBAC, substituir/complementar o conteúdo
   dessa mesma pasta, e reabrir a tela do Mapa Offline — nenhum novo APK é
   necessário.

Isso resolve o dilema de tamanho: o APK continua leve (só os tiles de
exemplo vêm embutidos), e o volume de dados do mapa — que para o Brasil
inteiro em bom detalhe passa fácil de vários GB — fica solto no
pendrive/SD, sem limite prático de tamanho.

## Sobre o mapa offline — cobertura por região

O ponto `-15.6014, -56.0979` no código é só o **centro inicial da tela** ao
abrir o mapa — a cobertura real depende 100% de quais tiles (imagens de mapa)
você colocar em `assets/map_tiles/{z}/{x}/{y}.png`. O app em si funciona para
qualquer região do mundo.

Você pediu para começar com **Mato Grosso + Mato Grosso do Sul** e ampliar
depois, possivelmente para o **Brasil inteiro**. Importante ser direto sobre
uma limitação: os servidores públicos de tiles do OpenStreetMap (os mesmos
que geram o mapa em qualquer app grátis) proíbem download automatizado em
massa nos termos de uso deles — não é algo que eu (nem qualquer script) deva
fazer de forma automática, robótica, direto no servidor deles. A forma
correta e permitida é usar uma ferramenta feita para isso, que baixa
respeitando os limites de uso:

1. Baixe o **MOBAC** (Mobile Atlas Creator) — gratuito, com interface gráfica: https://mobac.sourceforge.io
2. Nele, desenhe a área desejada no mapa (ou importe um contorno em
   KML/Shapefile) — comece com MT + MS.
3. Escolha a fonte de mapa (ex: OpenStreetMap Mapnik) e o **intervalo de
   zoom**. Referência real de tamanho acumulado por zoom:

   | Zoom até | Detalhe                    | Mato Grosso + MS (retângulo que cobre os 2 estados) | Brasil inteiro |
   |---------:|----------------------------|-----------------------------:|---------------:|
   | 10       | Rodovias e cidades grandes | ~34 MB                       | ~0,26 GB        |
   | 11       | Rodovias + cidades médias  | ~130 MB                      | ~1 GB           |
   | 12       | Ruas principais            | ~500 MB                      | ~4 GB           |
   | 13       | Ruas locais                | ~2 GB                        | ~16 GB          |

   Como agora o mapa lê de uma pasta externa (SD/pendrive, sem limite
   prático de tamanho — veja seção anterior), você tem folga para ir até
   **zoom 13** em MT + MS sem problema (~2 GB). Se depois decidir expandir
   para o Brasil inteiro, **zoom 11–12** já dá uma cobertura nacional bem
   útil (rodovias e ruas principais) num tamanho gerenciável (~1–4 GB);
   reserve zoom 13+ só para as cidades onde você realmente dirige com
   frequência, senão o volume passa dos 15 GB rapidamente.
4. Exporte no formato "OSMAnd" ou "TMS" com estrutura `{z}/{x}/{y}.png` — se
   o MOBAC exportar com o eixo Y invertido (formato TMS clássico), renomeie as
   pastas ou ajuste conforme a documentação do MOBAC para bater com o padrão
   slippy map (`{z}/{x}/{y}.png`) que o app espera.
5. Copie o resultado para a pasta `NeonMaps/` no pendrive/SD (veja seção
   anterior) e aponte o app para ela em Configurações — sem recompilar nada.
   Se preferir embutir no próprio APK em vez de usar pasta externa, copie
   para dentro de `assets/map_tiles/` (substituindo o tile de exemplo) e
   repita o Caminho A ou B de build.

Isso é a única fonte de gargalo que exige uma ação manual sua — todo o resto
(compilação, estrutura do projeto, permissões, telas) já está pronto.

---

## Estrutura entregue

```
pubspec.yaml
AndroidManifest.xml          -> vai em android/app/src/main/AndroidManifest.xml
lib/main.dart
android/MainActivity.kt      -> chamadas viva-voz + sinal de ré nativo; o
                                 workflow do Caminho A injeta isso sozinho
                                 no lugar certo, com o package correto
assets/map_tiles/0/0/0.png   -> tile de exemplo (transparente), substitua pelos reais
.github/workflows/build-apk.yml -> build automático no Caminho A
main.dart                    -> cópia solta na raiz, pode ignorar/apagar; o que
                                 importa é lib/main.dart
```

Se for pelo Caminho B (build local), copie `android/MainActivity.kt` (deste
pacote) para dentro de `project/android/app/src/main/kotlin/<seu-pacote>/
MainActivity.kt`, trocando a primeira linha `package __PACKAGE__` pelo
package real gerado pelo `flutter create` (o mesmo processo que o workflow
do Caminho A faz sozinho).

## Permissões em runtime

O app solicita em tempo de execução: localização (`ACCESS_FINE_LOCATION`,
necessária para o velocímetro) e Bluetooth Connect (necessária no Android 12+
para monitorar o status do Bluetooth). Em centrais com Android mais antigo,
essas permissões já vêm concedidas via manifesto.

## Notas de performance

- O velocímetro roda em um `AnimationController` dedicado, suavizando a
  leitura do GPS a 60 FPS sem travar o resto da interface.
- `PopScope(canPop: false)` impede que o botão "voltar" do sistema minimize
  o launcher.
- `SystemUiMode.immersiveSticky` remove as barras de sistema, reforçando a
  sensação de firmware nativo da central.
