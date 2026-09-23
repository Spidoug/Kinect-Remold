# Auditoria de código-fonte — 2026-09-23

## Escopo

Revisão de arquitetura, build, instalação/desinstalação, runtime Linux, runtime Windows como referência funcional, firmware de áudio, transporte USB de câmera, ScannerPort, áudio, câmera virtual V4L2, câmera IP, SDK local, SynKinect Studio, versionamento, dependências, documentação e resíduos gerados.

A auditoria priorizou quatro invariantes do produto:

1. Windows funcional permanece como referência de comportamento do hardware.
2. No Linux, **Build** é a única etapa que pode instalar dependências, baixar firmware/fontes e compilar.
3. No Linux, **Install / Reinstall** é estritamente offline e consome somente o bundle pronto.
4. O repositório-fonte não carrega binários gerados, caches nem caminhos legados sem função real.

## Limpeza e legados removidos

- removido `drivers/windows/source/VERSION.txt`; `VERSION` na raiz é a única versão do produto;
- removida dependência morta de `jdeps` dos builders do Studio/Java runtime;
- removido o `--no-deps` do build Linux: o build completo sempre reconcilia dependências quando necessário;
- removido o antigo `--no-deps`/modo de compatibilidade do instalador Linux;
- removida a alteração persistente do usuário chamador para os grupos `video,audio`;
- removido fallback de firmware durante a instalação: firmware só pode entrar pelo bundle validado no build;
- removidos diretórios de saída vazios e verificado que não existem `.o`, `.obj`, `.class`, `.jar`, `.ko`, `.exe`, `.dll`, temporários ou backups no fonte;
- documentação antiga que dizia que Install/Reinstall recompilava foi corrigida.

Compatibilidades mantidas deliberadamente: scripts de entrada públicos/finos, referências de protocolo ao libfreenect, fallback WinUSB existente no Windows, dois headers Smart Tilt independentes e byte-idênticos (para builds de plataforma separados) e o watchdog final de fechamento do Studio.

## Correções funcionais Linux

### Vídeo 1414/1473

RGB/IR agora segue a sequência comprovada do Windows: motor de captura parado -> registradores do modo -> endpoint ISO 0x81 armado -> registrador 0x05 inicia o stream. O caminho anterior podia armar o ISO e logo depois reinicializar a engine.

Depth também foi alinhado: engine/projetor desligados -> registradores de profundidade -> endpoint ISO 0x82 armado -> projetor/depth habilitado em 0x06. Isso elimina a mesma classe de reset após o endpoint já estar armado.

Como Studio e câmera virtual consomem o mesmo transporte físico, essas correções ficam no ponto comum dos dois caminhos, sem introduzir dependência de libfreenect no runtime.

### Áudio 1473

- versão da firmware UAC aceita resposta não vazia em buffer amplo, em vez de exigir exatamente 96 bytes;
- timeout de controle para a etapa de firmware alinhado a 10 s, como no Windows funcional;
- Studio só recebe endpoint de áudio quando a captura ALSA realmente abriu/configurou;
- fan-out de áudio é não bloqueante: cliente local lento é descartado em vez de bloquear os quatro canais e os demais consumidores;
- conversão PCM S16/S24 evita shifts/casts dependentes de implementação.

### Ciclo de vida / concorrência

- Broker, Scanner/câmera e câmera IP acompanham clientes ativos antes de destruir estado global/contexto USB;
- limites de clientes e timeouts impedem sockets locais abandonados de bloquear serviços indefinidamente;
- handlers de threads destacadas capturam exceções e liberam contadores/assinaturas por RAII;
- helpers de socket tratam envio zero, timeout inválido, criação de diretório e endereços UNIX de forma estrita;
- gravação de manifests/mapas usa arquivo temporário, flush/checagem e rename controlado.

### Studio após desinstalação

No Linux, a ausência de `/run/kinect360-remold/devices.tsv` agora significa runtime removido/parado e limpa imediatamente o registro do Studio. A janela de reconexão de 30 s continua apenas enquanto o runtime Linux está vivo, preservando tolerância a uma reencriptação USB curta sem deixar dispositivos fantasmas após uninstall.

## Build e instalação Linux

- build instala/reconcilia compilador, CMake, pkg-config, libusb, ALSA, OpenCV, libjpeg, kmod, systemd/udev, utilitários de contas e headers do kernel;
- Arch usa o `pkgbase` real do kernel quando disponível para escolher o pacote de headers correto;
- build baixa/verifica/extrai `UACFirmware 01.02.709.00` do Kinect Runtime v1.8 ou aceita a mesma imagem exata via override de build offline;
- build baixa, verifica, compila e empacota `v4l2loopback 0.15.4` para o kernel em execução;
- bundle grava versão do kernel, versão da fonte, SHA-256 da fonte e SHA-256 do `.ko`;
- build valida uma lista completa de artefatos antes de declarar sucesso;
- instalação não possui `apt`, `dnf`, `pacman`, `curl` nem `wget`;
- instalação valida todos os arquivos obrigatórios, resolução dinâmica (`ldd`), firmware, kernel e hashes do módulo antes de remover o runtime anterior;
- se o kernel mudou desde o build, a instalação para antes de modificar a instalação existente;
- falha de `modprobe` informa explicitamente kernel/headers/assinatura/Secure Boot em vez de baixar/compilar durante a instalação;
- `DIAGNOSE.sh` informa versão/build instalados e proveniência/integridade do módulo V4L2.

## Configuração, versionamento e dependências

- parser de configuração exige consumo completo de inteiros/doubles, rejeita NaN/Inf e conserva fallback para booleano inválido;
- CMake lê a versão canônica da raiz e adiciona warnings portáveis ao build GNU/Clang;
- builders Linux/Windows do Studio usam a versão raiz na metadata da Module API;
- o builder Windows confere `Product.psd1` contra a versão raiz;
- fontes externas críticas têm versão/hashes pinados; o instalador não resolve dependência pela rede.

## Validações executadas

- `bash -n` em todos os scripts `.sh`: PASS;
- C++17 estrito (`-Wall -Wextra -Wpedantic -Wconversion -Wshadow`) nos componentes sem dependências de hardware: PASS;
- CMake limpo com `REMOLD_BUILD_HARDWARE=OFF`: PASS;
- teste de regressão do parser de configuração: PASS;
- SynKinect Studio Module SDK com `javac -Xlint:all -Werror` e stub mínimo de `PApplet`: PASS;
- Smart Tilt Linux/Windows byte-idêntico: PASS;
- varredura do instalador Linux por download/package-manager: PASS;
- varredura de resíduos gerados/temporários no fonte: PASS;
- ausência de referências ao VERSION Windows removido e `jdeps`: PASS.

## Limites desta auditoria

O ambiente de auditoria não possui Kinect físico, headers nativos de libusb/ALSA/OpenCV, MSVC/WDK/PowerShell nem o conjunto completo de dependências do Processing/JOGL. Assim, não é correto afirmar aqui que o pacote hardware Linux, o pacote Windows ou o Studio completo foram executados fisicamente.

A validação final obrigatória é no Linux alvo, após `--rebuild`, com 1414 e 1473 conectados. O roteiro está em `docs/linux/PARITY-VALIDATION.md`.
