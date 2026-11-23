# lusmOS 4

Interface própria para o **R36S clone** (tela "sauce panel5", 640×480), feita em LÖVE.
Tema escuro em azul e roxo, quatro layouts (Grade, Cruz, Vitrine e Metrô), Wi-Fi,
coleções, pesquisa de jogos e atualização pela internet.

## Atualizar pelo console

Com o console no Wi-Fi: **Ajustes › Ferramentas › Atualizar o lusmOS**.
O console baixa a release mais nova deste repositório, confere o arquivo e instala.
Jogos, saves, favoritos e ajustes continuam como estão.

Ao ligar, o lusmOS também avisa quando sai uma versão nova
(dá para desligar em **Ajustes › Sistema › Procurar atualizações ao ligar**).

## Atualizar pelo cartão

Copie as pastas `lusmos/` e `boot/` deste repositório para a partição **BOOT** do cartão
(`lusmos/` vira `BOOT/lusmos` e o conteúdo de `boot/` vai direto na raiz da BOOT)
e ligue o console. A instalação roda sozinha no boot.

## Publicar uma versão nova

1. Faça as mudanças.
2. Troque o número em `lusmos/VERSION` (formato `4-AAAA.MM.DDx`, por exemplo `4-2026.11.24a`).
   O número novo precisa ser "maior" que o anterior: a data mais nova, ou a mesma data com a letra seguinte.
3. Opcional: escreva as notas em `notas/<versão>.md`. A primeira linha vira o título, que também aparece no console.
4. Envie para a branch `main`.

Quando o `lusmos/VERSION` muda, o GitHub monta o pacote (`tools/release.sh`) e publica a release `v<versão>` sozinho
(aba **Actions**). Os consoles com Wi-Fi passam a ver a atualização.

## Estrutura

| Pasta | O que tem |
|---|---|
| `lusmos/app` | A interface (Lua/LÖVE), fontes, sons e imagens |
| `lusmos/plymouth` | Tela de boot |
| `lusmos/launchimages` | Tela de entrada no jogo |
| `lusmos/*.sh` | Instalador, início do sistema, guarda, volume na tela e atualização online |
| `boot/` | Script de boot e animação de abertura |
| `tools/release.sh` | Monta o pacote da release |

O EmulationStation (aberto como app pelo lusmOS) não faz parte deste repositório:
ele já vem no sistema do console.

Fontes Poppins sob a SIL Open Font License (`lusmos/app/fonts/OFL.txt`).
