# 04 — Humanização (comportamento humano)

Objetivo: tirar da conta o perfil "robô perfeito" — fingerprint idêntico na frota,
online instantâneo ao conectar, digitação inexistente, nunca lê mensagens, nunca
erra, imagem idêntica para milhares de contatos.

| Função | Escopo | Default | Controle | Vale |
|---|---|---|---|---|
| Fingerprint por instância | todas | sempre ligado | código | próxima reconexão |
| Stealth connect | global + override | **ligado** | `antiban_stealth_connect` | próxima reconexão |
| Digitação/gravação (presença) | por campanha/item | "Digitando" em campanha nova | `presenceType`/`presenceTime` | imediato |
| Erros de digitação (typos) | allowlist + override | desligado | `antiban_typo_instances` | ~1 min |
| Read receipts humanizados | allowlist + override | desligado | `antiban_read_receipt_instances` | ~1 min |
| Ruído de fundo (entropy) | allowlist + override | desligado | `antiban_entropy_instances` | ~1 min |
| Imagem única por contato | por campanha | desligado | `sp_whatsapp_schedules.unique_media` | imediato |

## 1. Fingerprint de dispositivo por instância

**Problema:** toda instância subia com `['Linux','Chrome','96.0.4664.110']` (Chrome
de 2021). Frota com fingerprint idêntico = sinal de correlação entre contas.

**Solução:** `Antiban.deviceFingerprint(instance_id)` usa `generateFingerprint` da lib
com `seed = instance_id`, `deviceModelPool = ['Windows','Mac OS','Linux']`,
`osVersionPool = 12 versões do Chrome 122–133`, `randomizeAppVersion:false`.

- **Determinístico** → estável entre restarts sem persistir nada. Mudar fingerprint
  a cada reconexão seria, por si só, um sinal.
- **Não** toca no campo `version` do `makeWASocket` (vem do `cachedWaVersion`, versão
  real do WhatsApp Web).

## 2. Stealth Connect

**Problema:** o fork manda `sendPresenceUpdate('available')` ao abrir a conexão
(`markOnlineOnConnect` default `true`). "Snapar online" e já disparar é padrão de bot.

**Solução:**
1. `makeWASocket({ markOnlineOnConnect: !stealth })` → fork manda `unavailable` ao abrir.
2. No `connection 'open'`, `Antiban.rampPresence(WA, id)` usa `rampPresenceAfterConnect`
   (lib) para mandar `available` após 30–120 s aleatórios.
3. `AbortController` por instância: `close`/`logout()` cancela a rampa; `AbortError` é engolido.

Risco baixíssimo (só adia um broadcast de presença) → ligado por padrão, global.

## 3. Presença: digitando / gravando

`Antiban.simulatePresence(sock, chat_id, item)` antes de **todo** envio via `auto_send`.

- **Modelo WPM** do `PresenceChoreographer`: 45 WPM ± 15 (gaussiano), think-pauses,
  mínimo 1,5 s / máximo 25 s, multiplicador **circadiano** (perfil `default`,
  fuso `America/Sao_Paulo`: dia normal, 22h–02h mais lento, 02h–06h 4–6× mais lento).
- **Desde 2026-10-03** o tempo total obedece o `presenceTime` configurado no painel:
  o plano do choreographer mantém o *ritmo* (digitando/pausa) mas é reescalado para
  somar exatamente `presenceTime`. O painel só sugere `len/3,75` chars/s (2–25 s).
- `presenceType 2` (gravando áudio) usa duração fixa.

## 4. Erros de digitação (LegitimacySignalInjector)

Em `process_send_message`, para **texto puro** das instâncias habilitadas:

```js
const typo = Antiban.humanizeText(instance_id, data.text);   // null na maioria das vezes
if (typo) {
  await sock.sendMessage(chat_id, { ...data, text: typo.typoText });  // versão com erro
  await sleep(typo.correctionDelay);                                  // 500–2000 ms
  data = { ...data, text: typo.correctionText };                       // "*palavra" ou texto todo
}
// envio normal segue → só ELE grava histórico/stats (sem contagem dobrada)
```

- Probabilidade `antiban_typo_probability` (default 0,02 = 2 %).
- A lib ignora texto ≤ 10 caracteres e texto com URL; texto < 30 caracteres recebe
  correção com o texto inteiro.
- `enableReadGaps` sempre `false`; `typing_pauses` configurável (default `false`).
- Falha no envio do typo → segue com o envio normal.

> Atenção: gera uma mensagem extra real no chat do destinatário. Avaliar se é
> aceitável para o caso de uso antes de ligar.

## 5. Read receipts humanizados (readReceiptVariance)

No `messages.upsert`, para mensagens **recebidas em DM** (`user_type === 'user'`):

```js
Antiban.markReadHumanized(WA, instance_id, message.key, message.messageTimestamp);
```

- Atraso gaussiano: média 1500 ms, desvio 800 ms, mínimo 400 ms, máximo 8000 ms.
- Backlog (mensagem com mais de 60 s) é marcado **na hora**.
- `sock.readMessages()` respeita a config de privacidade da conta (`read` ou `read-self`).
- Nunca marca grupo. Fire-and-forget, nunca afeta o processamento da mensagem.

Combate o perfil "conta que só envia e nunca lê".

## 6. Ruído de fundo (HumanEntropyService)

Por instância conectada e habilitada, a cada 2–6 h (aleatório):

- digitando 3–8 s para um contato recente e para ("começou a digitar e desistiu");
- marca uma mensagem recebida como lida com atraso de 10–60 min;
- alterna presença `available` → `unavailable` em 30–120 s.

**Segurança:** só interage com quem **mandou mensagem primeiro** (alimentado por
`feedEntropy`, só DM). Nunca contata estranhos.

**Adaptação:** a classe da lib foi feita para o WaSP (espera `.on('MESSAGE_RECEIVED')`
e `.getProvider(id) → { socket }`). O projeto cria um `EventEmitter` por instância
que faz esse papel e resolve o socket vivo a cada ciclo via
`setEntropySocketResolver(id => sessions[id])` — sobrevive a reconexão.

Ciclo de vida: `startEntropy` no `open` · `stopEntropy` no loggedOut/`logout()` ·
`reconcileEntropy` no cron de 30 s (liga/desliga conforme a flag sem esperar reconexão).

## 7. Imagem única por contato (`unique_media`)

**Problema:** o mesmo arquivo para N contatos → o mesmo `fileSha256` em todas as
mensagens, assinatura clássica de disparo em massa.

**Solução** (`waziper/media_variant.js`, só `type == 'bulk'` via Baileys):
- baixa a imagem uma vez (cache de 10 min, até 10 itens, máx. 16 MB);
- para cada envio insere bytes aleatórios num bloco de **metadado**:
  JPEG → segmento `COM` (FF FE) logo após o SOI; PNG → chunk `tEXt` após o IHDR
  (com CRC32 correto);
- os pixels não mudam (visualmente idêntica), o hash muda por contato;
- custo desprezível (só bytes, sem decodificar; sem sharp/jimp);
- formato não suportado (webp, gif…) ou erro → envia a URL original.

API oficial (`login_type = 1`) não é afetada.

## 8. Canonicalização LID ↔ PN

Não é humanização, mas é parte da higiene da sessão: `canonicalizeJid` (antes de
todo envio) e `learnFromUpsert` (todo upsert) evitam a corrida `@lid` /
`@s.whatsapp.net` que gera **Bad MAC** / falha de descriptografia — um sinal
indireto de sessão degradada. Até 2026-09-02 isso não rodava (fábrica
`getCanonicalizer` inexistente, tudo caía no `catch`).

## 9. Resolvedor @lid gotejado (LidResolver) — com cuidado

`client.onWhatsApp(jid)` é **descoberta de contato em lote** — padrão que o
anti-spam bane. Por isso o `lid_resolver.js` é opt-in por conta e amarrado ao antiban:
teto ~6 lookups/hora com jitter (4–18 min), janela 08h–21h, 1 por vez, **nunca**
com a conta em health pause nem com campanha ativa, e **disjuntor**: o primeiro
429/403/428/440 (ou queda severa até 10 min após um lookup) aborta a conta.
Regra de ouro: sem aceite explícito do cliente, use a via passiva (`key.remoteJidAlt`).
