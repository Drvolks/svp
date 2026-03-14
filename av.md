# AV Debug Log

Date: 2026-03-12
Repo: `/Users/jfdufour/git-repositories/svp`

Objectif:
- Stabiliser le playback live TS audio/video.
- Garder PiP/custom pipeline viable.
- Eviter de répéter les mêmes expériences sous des noms plus sophistiqués.

## Etat courant

Ce qui est solide:
- Audio TS est décodé correctement.
- Le parser TS ne crashe plus sur resync.
- `PlaybackSession` est séparé en workers `demux / audio / video decode / video present`.
- La queue vidéo décodée est triée par PTS.
- Le slideshow causé par des bursts de `submit` a été partiellement réduit avec un pacing live ancré.

Ce qui reste cassé:
- Le sync A/V live n'est pas stabilisé.
- Certaines tentatives de gating live reviennent à "2 frames puis coma".
- Certaines tentatives de compensation A/V améliorent le sync mais détruisent la fluidité.

## Règles de travail

A faire:
- Logger chaque changement de politique A/V ici avant ou juste après le patch.
- Noter explicitement:
  - hypothèse
  - fichiers touchés
  - symptôme attendu
  - symptôme observé
  - verdict

A éviter:
- Réintroduire un tweak déjà essayé sans raison nouvelle mesurée.
- Corriger le sync live avec une estimation indirecte de backlog si on n'a pas une preuve instrumentée.
- Mélanger "fluidité", "sync", "queue backlog", "renderer" dans un seul changement.

## Baseline technique actuelle

Fichiers clés:
- `/Users/jfdufour/git-repositories/svp/Sources/PlayerCore/PlaybackSession.swift`
- `/Users/jfdufour/git-repositories/svp/Sources/PlayerCore/PacketQueue.swift`
- `/Users/jfdufour/git-repositories/svp/Sources/PlayerCore/FrameQueue.swift`
- `/Users/jfdufour/git-repositories/svp/Sources/Audio/AudioRenderer.swift`
- `/Users/jfdufour/git-repositories/svp/Sources/Demux/TSTransportParser.swift`
- `/Users/jfdufour/git-repositories/svp/Sources/Input/LiveTSInputSource.swift`
- `/Users/jfdufour/git-repositories/svp/Sources/Render/MetalRenderer.swift`

Instrumentation utile disponible:
- `[SVP][AudioClock] ...`
- `queue_health context=...`
- `video_timing context=...`
- `[SVP][Render] submit ...`
- `[SVP][Render] draw ...`

## Journal des essais

### 1. Separation demux / audio / video decode / video present

Hypothèse:
- Une boucle unique crée du couplage toxique audio/video.

Changement:
- Refactor de `PlaybackSession` en workers séparés.

Résultat:
- Base plus saine.
- A aidé sur plusieurs symptômes, mais n'a pas suffi pour le live TS.

Verdict:
- Garder.

### 2. Queue de frames vidéo triée par PTS

Hypothèse:
- Des frames légèrement hors ordre produisent un rendu visuellement choppy même si les timings paraissent corrects.

Changement:
- `FrameQueue` insert les `DecodedVideoFrame` triés par `pts`.

Résultat:
- Amélioration visible sur le MP4 720p de test.

Verdict:
- Garder.

### 3. Politique live `frameCapacity=18` + `dropOldest`

Hypothèse:
- Une petite queue live avec priorité au récent réduira la latence.

Résultat observé:
- Pire.
- Files plus souvent vides.
- Récupération moche.
- Rendu encore plus cassé.

Verdict:
- Ne pas réintroduire tel quel.

### 4. Trim brutal / backlog cutting en live

Hypothèse:
- Si la queue vidéo est trop en avance, la tailler massivement recollera au live.

Résultat observé:
- Pire.
- Perception dégradée immédiatement.

Verdict:
- Ne pas réintroduire.

### 5. Forcer le renderer live à 50 fps

Hypothèse:
- Le flux live était traité comme du 50 fps.

Résultat observé:
- Mauvais sur les flux ~30 fps.
- Ajoutait du judder.

Verdict:
- Ne pas forcer 50 fps par défaut.

### 6. Lock du framerate estimé du renderer

Hypothèse:
- Eviter les oscillations 24/30/50 du renderer.

Résultat:
- Correct pour éviter le flip-flop.
- Ne règle pas à lui seul le problème live.

Verdict:
- Garder, mais ne pas sur-vendre.

### 7. Live TS via `URLSession.data(from:)`

Hypothèse:
- Le flux HTTP live allait passer correctement.

Résultat observé:
- Non. Attente du body complet.
- Live pratiquement bloqué.

Correction:
- `LiveTSInputSource` utilise maintenant `URLSession.bytes(for:)`.

Verdict:
- Garder la version streaming bytes.

### 8. Classification audio TS private stream (`0x06`)

Hypothèse:
- L'audio TS n'était pas détecté correctement à cause des descripteurs PMT.

Changement:
- `TSTransportParser` reconnaît `AC3`, `EAC3`, `AAC` via descripteurs PMT.

Résultat:
- A permis au chemin audio TS de réellement passer au decodeur.

Verdict:
- Garder.

### 9. Drain audio FFmpeg multi-frames

Hypothèse:
- Un paquet PES audio peut produire plusieurs frames, et le pont FFmpeg n'en sortait pas assez.

Changement:
- Drain complet des frames audio via le bridge FFmpeg.

Résultat:
- Audio TS beaucoup plus stable.
- Disparition des rafales `audio_decode_drop ... decodeFailed(-35)`.

Verdict:
- Garder.

### 10. Horloge audio "jouée" bricolée depuis backlog audio

Hypothèse:
- `lastAudioPTS - queuedAudioSeconds` pourrait approximer le temps réellement joué.

Résultat observé:
- Très fragile.
- A causé des freezes / presenter bloqué sur certains essais.

Verdict:
- Ne pas réintroduire cette approximation.

### 11. Horloge audio jouée via `AVAudioPlayerNode.playerTime`

Hypothèse:
- Une vraie clock issue de `playerTime(forNodeTime:)` est meilleure que `lastAudioPTS`.

### 25. Clock audio basée sur sampleTime relatif a l'ancre

Hypothèse:
- `playerTime.sampleTime` du `AVAudioPlayerNode` est absolu sur la timeline du node.
- Si on l'ajoute directement a `anchorPTS`, on invente un drift progressif.

Changement:
- `AudioRenderer` stocke maintenant `playbackAnchorSampleTime`.
- `currentPlaybackTime()` calcule:
  - `elapsedSamples = playerTime.sampleTime - playbackAnchorSampleTime`
  - puis `anchorPTS + elapsedSeconds`

Symptome attendu:
- `derivedPTS` ne doit plus partir plusieurs secondes devant la video split/VOD.
- Le drift A/V progressif devrait baisser nettement.

Verdict:
- En cours.

### 26. Split VOD ne doit pas utiliser le presenter live

Hypothèse:
- Le split A/V VOD passe dans `presentLiveFrames(...)` uniquement parce que `preferredLeadSeconds > 0`.
- Ce chemin ignore l'horloge audio et cadence sur l'ancre vidéo, donc drift assuré.

Changement:
- Le choix `live presenter` dépend maintenant de `descriptor.isLive`, pas seulement de `preferredLeadSeconds`.
- Le split VOD garde un `preferredLeadSeconds` faible, mais passe par `pace(...)` avec `masterClockProvider`.

Symptome attendu:
- Moins de drift progressif sur `videoURL + audioURL`.
- Plus de cohérence entre `audioClock` et `framePTS`.

Verdict:
- En cours.

### 27. Filtrage explicite des streams en mode split

Hypothèse:
- L'URL "video" peut contenir aussi de l'audio, et l'URL "audio" ne doit fournir que l'audio.
- Fusionner tous les streams des deux demuxers pollue le split A/V et peut créer du drift.

Changement:
- `SplitAVDemuxEngine` forwarde maintenant:
  - seulement `.h264/.hevc` depuis le demux video
  - seulement `.aac/.ac3/.eac3/.opus` depuis le demux audio

Symptome attendu:
- Split A/V plus cohérent.
- Moins de dérive liée à des packets audio dupliqués ou mélangés.

Verdict:
- En cours.

### 28. Instrumentation de la fusion split

Hypothèse:
- Le gel split peut venir d'un côté (audio ou vidéo) qui atteint EOF ou cesse de forwarder bien avant l'autre.

Changement:
- `SplitAVDemuxEngine` loggue maintenant:
  - `video_forward`
  - `audio_forward`
  - `video_eof`
  - `audio_eof`

Symptome attendu:
- Permettre d'identifier si le split casse dans la fusion ou plus bas dans le pipeline.

Verdict:
- En cours.

Résultat actuel:
- La formule instrumentée semble cohérente en elle-même:
  - `anchorPTS=-0.021`
  - `sampleTime` progresse
  - `derivedPTS` progresse normalement
- Mais brancher directement un gating live pur sur cette clock a encore produit un freeze "2 frames puis plus rien".

Verdict:
- La source de temps mérite d'être gardée pour instrumentation.
- Son usage direct comme gate live n'est pas encore validé.

### 12. Presenter live sans gating audio, pacing vidéo ancré

Hypothèse:
- Retrouver une baseline fluide avant de viser un sync parfait.

Résultat:
- Meilleure fluidité.
- Sync A/V dérive.
- Petits bursts / fast-forward encore visibles.

Verdict:
- Bonne baseline provisoire de fluidité.

### 13. Presenter live avec cadence inter-frame

Hypothèse:
- Le presenter relâchait les frames en rafales.

Résultat:
- Confirmé par logs:
  - avant: `submitIntervalMs` énorme puis quasi nul
  - après: intervalle bien plus régulier

Verdict:
- Garder.

### 14. Compensation live par backlog audio réel

Hypothèse:
- Retarder la vidéo de la valeur de queue audio pour recoller au son.

Résultat observé:
- `video_live_drop` massif
- fluidité détruite

Verdict:
- Ne pas réintroduire.

### 15. Etat juste avant ce log

Log utilisateur:
- `AudioClock query=60 anchorPTS=-0.021 sampleTime=26624 sampleRate=48000 derivedPTS=0.533 queued=0.683`
- `AudioClock query=120 ... derivedPTS=1.824 queued=0.747`
- `AudioClock query=180 ... derivedPTS=3.115 queued=0.661`
- `AudioClock query=240 ... derivedPTS=4.427 queued=0.704`
- `AudioClock query=300 ... derivedPTS=5.728 queued=0.597`

Interprétation:
- La formule `anchorPTS + sampleTime/sampleRate` semble raisonnable.

### 23. Politique split A/V dédiée

Hypothèse:
- Une source `videoURL + audioURL` n'est pas un VOD muxé classique.
- Sans politique dédiée, l'audio peut prendre plusieurs secondes d'avance en queue et la vidéo finit par s'enfarger.

Changement:
- Source `.split`:
  - `audioCapacity = 96`
  - backpressure dédié:
    - audio `0.35s`
    - video packets `0.80s`
    - video frames `0.25s`
  - pacing vidéo léger sur clock audio avec `preferredLeadSeconds = 0.04`

Résultat attendu:
- Moins de dette audio.
- Moins de drift progressif.
- Split MP4 plus stable sur la durée.

Statut:
- En test.

Observation:
- Le throttling global d'ingestion appliqué au mode split a empiré les choses.
- Comme audio et vidéo arrivent via un flux fusionné, freiner l'ingestion entière dès que l'audio dépasse un petit seuil affame directement la vidéo.

Verdict partiel:
- Garder la capacité audio split plus basse.
- Ne pas appliquer `throttleLiveIngestionIfNeeded()` au split.

### 24. Backpressure audio split ciblé

Hypothèse:
- En split A/V, seule la queue audio dérive fortement.
- Freiner toute l'ingestion casse la vidéo.
- Il faut donc temporiser uniquement l'enqueue des paquets audio split.

Changement:
- Ajout de `throttleSplitAudioIngestionIfNeeded()`.
- Appliqué seulement avant `audioPacketQueue.enqueue(packet)` pour les sources `.split`.
- Seuil: `splitAudioPacketBacklogSoftLimitSeconds = 0.35`.

Résultat attendu:
- Moins de backlog audio split.
- Moins de drift A/V.
- Pas d'affamement vidéo.

Statut:
- En test.

### 29. Presenter VOD split + faux EOF multi-demux + clear renderer

Hypothèse:
- Le split YouTube se dégrade à trois endroits distincts:
  - le bridge FFmpeg multi-input peut signaler EOF alors qu'un seul côté manque momentanément,
  - le presenter VOD dépile en FIFO sans tenir compte des frames éligibles sur l'horloge audio,
  - le renderer Metal ne clear pas le drawable avant l'aspect-fit, ce qui peut laisser du "burning".

Changement:
- `CShim.c`
  - le multi-demux sort maintenant le paquet vidéo ou audio disponible le plus tôt,
  - il ne retourne plus EOF tant que les deux côtés ne sont pas réellement terminés.
- `PlaybackSession.swift`
  - le split VOD revient à un `preferredLeadSeconds = 0.04`,
  - le presenter VOD réutilise `popLatestEligible(upTo:)` au lieu d'un FIFO aveugle.
- `MetalRenderer.swift`
  - clear explicite du drawable en noir avant le render CoreImage.

Symptôme attendu:
- Moins de shutter sous livraison bursty du split A/V.
- Plus de cohérence entre `framePTS` et `audioClock`.
- Disparition des traces visuelles de frame précédente hors zone effectivement redessinée.

Statut:
- En test.

### 30. DTS transmis jusqu'au décodeur vidéo FFmpeg

Hypothèse:
- Le split H.264 continue de shutter parce que le bridge de decode envoie `dts = pts`.
- Sur un flux avec B-frames, ça casse l'ordre de décodage et peut retarder la première sortie vidéo d'un gros paquet de frames.

Changement:
- `CShim.h` / `CShim.c`
  - `svp_ffmpeg_video_decoder_decode(...)` reçoit maintenant `dts90k`.
- `FFmpegVideoDecoder.swift`
  - transmet `packet.dts ?? packet.pts` au bridge.
- `svp_ffmpeg_demuxer_create_multi(...)`
  - initialise aussi les `pending_*_dts` à `AV_NOPTS_VALUE`.

Symptôme attendu:
- Première frame vidéo rendue beaucoup plus tôt.
- Moins de buffering absurde au démarrage.
- Réduction nette du shutter si la vraie panne venait de l'ordre de décodage H.264.

Statut:
- En test.

### 31. Backpressure sur le vrai buffer audio renderer

Hypothèse:
- Le symptôme "avance rapide" ne vient pas d'un `rate` de lecture, mais d'un renderer audio qui accumule beaucoup trop de buffers en sortie.
- Une fois la queue `AVAudioPlayerNode` montée à ~2s, le pipeline se met à jeter des buffers (`queue_overflow`), ce qui saute du contenu audio et force la vidéo à courir derrière une horloge audio devenue trop optimiste.

Changement:
- `Models.swift`
  - ajout d'un protocole `AudioRenderBufferProviding` pour exposer le buffer audio réellement schedulé.
- `AudioRenderer.swift`
  - `AudioRenderer` expose `bufferedAudioSeconds()`,
  - hard cap renderer ramené à `0.80s` en VOD et `0.55s` en live au lieu de ~2s / 1.4s,
  - `currentPlaybackTime()` ignore les `sampleTime < 0` et ne laisse plus l'horloge repartir en arrière.
- `PlaybackSession.swift`
  - `throttleAudioDecodeIfNeeded(...)` se cale d'abord sur le vrai buffer renderer (`0.45s` VOD / `0.30s` live),
  - puis garde aussi un lead PTS plus serré (`0.30s` VOD).

Symptôme attendu:
- Disparition des rafales `drop_frame reason=queue_overflow`.
- Plus de sensation "fast forward" audio/vidéo.
- Horloge audio plus stable au démarrage et backlog renderer contenu sous ~0.5s au lieu de 2s.

Statut:
- En test.

### 32. Renderer Metal piloté par les frames, pas par une boucle libre

Hypothèse:
- Le pacing vidéo est redevenu correct, mais le rendu reste visuellement mauvais parce que `MTKView` tourne en draw loop autonome et n'affiche que le "latest frame" au prochain tick.
- Résultat probable:
  - répétition / écrasement de frames selon la cadence du display link,
  - sensation de shutter malgré une bonne horloge,
  - contenu précédent conservé lors des discontinuities parce que le renderer ne se reset pas vraiment.

Changement:
- `MetalRenderer.swift`
  - `MetalRenderer` implémente maintenant `VideoOutputLifecycle`,
  - `MTKView` passe en mode manuel (`enableSetNeedsDisplay = true`, `isPaused = true`),
  - chaque `render(frame:)` déclenche un `view.draw()` sur le main thread,
  - `handleDiscontinuity()` reset l'état renderer et force un draw vide,
  - `draw(in:)` clear/present maintenant même sans pixel buffer, donc plus de frame fantôme conservée au changement d'état.

Symptôme attendu:
- Moins de shutter causé par désalignement entre cadence de submit et cadence de draw.
- Disparition des frames "brûlées" conservées par le renderer après overwrite/discontinuity.
- Rendu piloté par les vraies frames présentées, pas par une horloge d'affichage indépendante.

Statut:
- En test.

### 33. Préférence hardware rétablie pour H.264/HEVC

Hypothèse:
- Les logs montrent encore un comportement typique du path FFmpeg software (`Reorder`, première frame tardive vers `1.668s`) alors qu'on croit utiliser `preferHardwareDecode = true`.
- Le vrai bug est dans `DefaultVideoPipeline`: dès qu'un fallback existe, il bypass le primaire et décode tout en software.

Changement:
- `VideoDecoder.swift`
  - `DefaultVideoPipeline.decode(packet:)` réutilise maintenant réellement le décodeur primaire,
  - FFmpeg fallback n'est utilisé que pour:
    - codecs à bypass explicite (`av1`, `vp9`),
    - codecs marqués `softwareForcedCodecs` après une erreur primaire compatible,
  - le reorder buffer reste réservé au path software.

Symptôme attendu:
- H.264/HEVC repassent sur VideoToolbox quand `preferHardwareDecode = true`.
- Disparition potentielle du shutter/burning propre au chemin FFmpeg software.
- Les prochains logs devraient arrêter de ressembler à un pipeline software forcé si le primaire tient.

Statut:
- En test.

### 34. Copie défensive des pixel buffers VideoToolbox

Hypothèse:
- Les artefacts restants (smudge sur les mouvements, blocs verts) ressemblent moins à un problème d'horloge qu'à un problème de buffer vidéo réutilisé trop tôt.
- Le path `VideoToolboxDecoder` renvoyait directement le `CVPixelBuffer` issu de VT, potentiellement recyclé par le pool avant que le renderer n'ait fini de l'afficher.

Changement:
- `VideoToolboxDecoder.swift`
  - copie maintenant chaque `CVPixelBuffer` VT dans un nouveau buffer propriétaire avant de le remettre au pipeline,
  - copie plan par plan avec clear préalable pour éviter tout résidu de lignes/planes précédents.

Symptôme attendu:
- Réduction nette du "burning"/smudge sur les zones en mouvement.
- Disparition des blocs verts/corruption globale si la cause était la réutilisation du buffer VT.

Statut:
- En test.

### 19. Pacing audio avant render

Hypothèse:
- Le worker audio cadencait l'audio après `output.render(frame:)`.
- Donc il remplissait d'abord la queue `AVAudioPlayerNode`, puis dormait ensuite.
- Effet attendu: queue audio qui gonfle, `queue_overflow`, dérive A/V, puis drops vidéo induits.

Changement:
- Dans `PlaybackSession.consumeAudioPackets()`, `paceAudioIfNeeded(framePTS:)` est appelé avant `output.render(frame:)`.

Résultat attendu:
- Moins de dette audio artificielle.
- Moins de `drop_frame reason=queue_overflow`.
- Moins de dérive A/V au long cours.

Statut:
- En test.

### 20. Seuils live séparés audio / video

Hypothèse:
- Le live utilisait le même seuil de throttling (`1.5s`) pour backlog audio et vidéo.
- C'est trop généreux pour l'audio maître: on laisse l'audio prendre de la dette, puis la vidéo finit devant, puis ça saccade.

Changement:
- `liveAudioPacketBacklogSoftLimitSeconds = 0.45`
- `liveVideoPacketBacklogSoftLimitSeconds = 1.20`
- `liveFrameBacklogSoftLimitSeconds = 0.35`

Résultat attendu:
- Moins de dette audio accumulée.
- Moins de drift A/V sur la durée.
- Moins de rattrapage vidéo tardif.

Statut:
- En test.

### 21. Throttle du decode vidéo live avant enqueue

Hypothèse:
- Même avec un presenter plus sain, la vidéo live est encore produite trop en avance sur l'audio joué.
- Résultat: A/V drift, puis petits rattrapages visibles.

Changement:
- Avant `videoFrameQueue.enqueue(...)`, si une frame vidéo live est trop en avance sur `currentAudioClockForPresentation()`, on temporise le chemin decode par petits pas.
- Seuil de lead doux: `0.18s`.

Résultat attendu:
- Réduire l'avance vidéo sans recharger le presenter en logique de sync.
- Moins de drift progressif et moins de bursts de rattrapage.

Statut:
- En test.

### 22. Cache de la clock audio jouée

Hypothèse:
- `AVAudioPlayerNode.playerTime(forNodeTime:)` peut être indisponible ponctuellement.
- Dans ce cas, `PlaybackSession` retombe sur `lastAudioPTS`, ce qui mélange clock jouée et clock décodée.
- Effet attendu: drift A/V puis rattrapages vidéo irréguliers.

Changement:
- `AudioRenderer` garde `lastDerivedPlaybackPTS`.
- Si `playerTime` n'est pas dispo sur une query, on renvoie la dernière valeur valide au lieu de `nil`.

Résultat attendu:
- Clock audio plus monotone et cohérente.
- Moins de bascules implicites vers `lastAudioPTS`.
- Moins de rattrapages vidéo tardifs.

Statut:
- En test.
- Le problème n'est plus "l'horloge n'avance pas".
- Le problème est la politique de présentation qui utilise ou retient cette clock de façon instable.

Verdict:
- Prochaine itération doit être isolée et documentée ici avant patch.

### 16. Presenter live en 2 phases (`startup` puis `sync armed`)

Hypothèse:
- Le problème n'est pas forcément la vraie audio clock elle-même, mais le fait d'obéir trop tôt à cette clock pendant le démarrage live.

Changement:
- Le `VideoPresenter` live démarre sans gating audio.
- Il arme le sync seulement après plusieurs lectures audio clock:
  - valides
  - monotones
  - avec deltas plausibles
- Un log `video_live_sync_armed ...` est émis à l'armement.

Résultat observé:
- Non viable dans l'état actuel.
- Retour du symptôme "2 frames puis coma".
- Le gating sur vraie audio clock, même armé plus tard, reste capable de bloquer le presenter live.

Verdict:
- Ne pas réintroduire tel quel.

### 17. Correction progressive de sync live inspirée mpv

Hypothèse:
- Le presenter live ne doit pas gater brutalement sur l'audio clock.
- Il doit corriger progressivement un offset vidéo borné à partir de l'erreur `framePTS - audioClock`.

Changement:
- Ajout d'un `liveSyncOffsetSeconds` dans le `VideoPresenter`.
- Mise à jour progressive avec:
  - gain faible
  - step max borné
  - clamp global
- Le pacing live ancré ajoute cet offset au `targetUptime`.
- Log:
  - `video_live_sync_offset offset=... avError=... step=...`

Résultat observé:
- Non viable dans l'état actuel.
- Retour d'un mode `video_live_drop` quasi permanent.
- Dégradation vers slideshow.

Verdict:
- Ne pas réintroduire tel quel.

### 18. Refactor profil audio live / vod

Hypothèse:
- Une partie du faux décalage A/V live vient d'une dette audio que nous créons nous-mêmes avec un buffer trop gros.
- Il faut réduire la latence audio live à la source, pas forcer ensuite le presenter vidéo à mentir.

Changement:
- `AudioRenderer` expose maintenant des profils explicites:
  - `vod`
  - `live`
- Le profil live réduit:
  - `baseStartBufferSeconds`
  - `maxStartBufferSeconds`
  - `maxBufferedAudioSeconds`
  - seuil low-water
- `PlaybackSession.load(...)` configure les outputs audio selon `MediaSourceDescriptor.isLive`.

Résultat attendu:
- moins de backlog audio live permanent
- moins de pression pour retarder artificiellement la vidéo
- meilleure base pour un sync live sans casser la fluidité

Verdict:
- En cours de test.

Note intermédiaire:
- Le départ live est meilleur.
- Mais le plafond `maxBufferedAudioSeconds=0.9` pour le profil live s'est révélé trop agressif.
- Symptôme:
  - rafales de `drop_frame reason=queue_overflow queued=0.917... max=0.9`
  - dégradation ensuite de la fluidité

Ajustement:
- `live.maxStartBufferSeconds` monte à `0.75`
- `live.maxBufferedAudioSeconds` monte à `1.4`

Deuxième ajustement:
- Le `late frame drop` live utilisait encore `lastAudioPTS`.
- Or cette horloge est plus optimiste que la vraie audio clock jouée.
- Correction:
  - `shouldDropLateVideoFrameAsync(...)` compare maintenant la frame vidéo à `currentAudioClockForPresentation()`.

But:
- arrêter les `video_live_drop` déclenchés par une mauvaise référence de temps.

Troisième ajustement:
- Réduction de la dette vidéo live sans réintroduire `dropOldest`.
- `frameCapacity` live passe de `48` à `18` quand audio+video sont présents.
- `framePolicy` reste `blockProducer`.

Raison:
- Le backlog vidéo live restait autour de `1.5s`.
- Le symptôme n'était plus "pas assez de frames", mais "trop de dette vidéo décodée".
- On veut réduire la dette, pas réintroduire une politique de drop destructrice.

## Prochaines pistes autorisées

1. Mesurer l'écart entre:
- `derived audio clock`
- `lastAudioPTS`
- `framePTS`
- `submitIntervalMs`

2. Introduire une politique live explicite de presenter, mais seulement si:
- on isole clairement:
  - fluidité
  - sync
  - drops

3. Si une nouvelle idée touche à l'horloge live:
- la consigner ici avant de la brancher au presenter.

## Pistes interdites sans nouvelle preuve

- Refaire `frameCapacity=18 + dropOldest`
- Refaire le trim brutal live
- Reforcer `50 fps`
- Refaire `lastAudioPTS - queuedAudioSeconds`
- Réintroduire des drops vidéo massifs basés sur backlog audio

### 19. Patch minimal AV1/VP9 (software FFmpeg path)

Hypothèse:
- Le player ignore AV1/VP9 avant même d'arriver au decode (enum/mapping/filtres trop restrictifs).

Changements:
- `CodecID` étendu avec `.av1` et `.vp9`.
- Bridge C (`CShim.c`): mapping FFmpeg <-> bridge ajouté pour AV1/VP9.
  - `AV_CODEC_ID_AV1` <-> `7`
  - `AV_CODEC_ID_VP9` <-> `8`
- Demux FFmpeg Swift: mapping `7/.av1`, `8/.vp9`.
- `FFmpegVideoDecoder` accepte AV1/VP9 et crée le decoder FFmpeg avec IDs `7/8`.
- `SplitAVDemuxEngine` considère AV1/VP9 comme paquets vidéo valides.
- `PlaybackSession` route AV1/VP9 vers la queue vidéo (au lieu de les ignorer).

Résultat build:
- Pas d'erreur de compilation liée au patch codec.
- Build complet reste bloqué par un problème séparé de ressources `AVSmoke` manquantes (`1-h264.mp4`, `1-h264.aac`).

Verdict:
- Base AV1/VP9 branchée bout en bout côté software decode FFmpeg.
- Reste à valider en lecture réelle (surtout sync/stabilité), mais le pipeline ne filtre plus ces codecs par défaut.

### 20. AVC1/HEVC doivent rester sur VideoToolbox

Problème:
- Le pipeline vidéo utilisait un verrou global `fallbackLocked`.
- Après un fallback software sur un codec (ex: AV1/VP9), on pouvait rester coincé en software pour AVC1/HEVC.

Changement:
- Remplacement du verrou global par une stratégie par codec (`softwareForcedCodecs`).
- `preferHardware=true`:
  - AV1/VP9 bypassent directement le primaire (VT) et vont en FFmpeg software.
  - AVC1/HEVC continuent de passer par VideoToolbox en priorité.
- Le forçage software persistant est appliqué seulement sur erreurs de capacité du primaire (`unsupported/backend/sessionCreationFailed`) et par codec.

Résultat attendu:
- AVC1 reste hardware decode (VT) même si AV1/VP9 utilisent software.

### 21. VideoToolbox: resync strict sur keyframe après erreur recoverable

Hypothèse:
- Le chemin VT continuait à avaler des P/B-frames après `kVTInvalidPictureErr (-8969)`.
- `reset + retry + skip` sans resync explicite laisse le décodeur repartir au milieu d'un GOP sale.
- C'est exactement le genre de bricolage qui produit des bavures et des blocs verts "assez valides pour passer".

Changements:
- `VideoToolboxDecoder` garde maintenant un état `requiresKeyframeResync`.
- Si VT prend une erreur recoverable sur une inter-frame:
  - on reset la session,
  - on bascule en attente de keyframe,
  - on remonte `VideoDecodeError.needsKeyframe` au lieu de juste `return nil`.
- Si l'erreur recoverable arrive sur une keyframe:
  - on retente une seule fois après reset,
  - si ça échoue encore, on attend explicitement la prochaine keyframe.
- Les paquets non-keyframe sont rejetés tant que le resync n'a pas été fait.
- Le sample buffer VT marque maintenant explicitement les inter-frames avec `kCMSampleAttachmentKey_NotSync`.
- La soumission VT n'utilise plus `_EnableAsynchronousDecompression` ici.
  - Le pipeline attend déjà frame par frame, donc l'asynchronisme ne faisait qu'ajouter de l'ambiguïté à la récupération et au cycle de vie des buffers.

But:
- empêcher VT de continuer sur des références mortes après une erreur recoverable,
- forcer une vraie reprise sur image intra,
- réduire les artefacts persistants au lieu de juste masquer des échecs decode.

Addendum:
- Le passage en decode VT strictement synchrone a ensuite révélé un nouveau défaut:
  - le décodeur ne tenait plus le débit réel du flux,
  - le presenter finissait par tomber en `queue empty` permanent,
  - visuellement: vidéo qui part, puis freeze alors que l'audio continue.
- Correction:
  - réactivation de `_EnableAsynchronousDecompression`,
  - tout en gardant:
    - la copie défensive du `CVPixelBuffer`,
    - le resync strict sur keyframe après erreur recoverable,
    - le marquage `NotSync` des inter-frames.

But:
- récupérer le débit VT sans réintroduire les corruptions qu'on vient d'éliminer.

### 22. Catch-up VOD quand la vidéo tombe derrière l'audio

Constat log:
- Le renderer ne corrompt plus rien, mais la vidéo finit plusieurs secondes derrière l'audio.
- Ensuite le presenter droppe chaque frame comme "late" et reste figé sur la dernière image rendue.
- Continuer à décoder tous les vieux paquets vidéo dans cet état est absurde: on paie le decode, puis on jette tout.

Correction:
- Ajout d'un rattrapage VOD explicite dans `PlaybackSession`.
- Si la vidéo a plus de `0.80s` de retard sur l'audio:
  - on déclenche un `video_catchup_resync`,
  - on flush le pipeline vidéo,
  - on purge les queues vidéo paquets + frames,
  - on repasse en attente de keyframe.
- Cooldown court (`0.75s`) pour éviter de thrash le pipeline.

But:
- arrêter de décoder des frames déjà condamnées,
- permettre au demux/decode de sauter l'historique vidéo périmé,
- repartir sur une keyframe utile au lieu de finir en freeze permanent.

### 23. `play()` réentrant: double lancement des workers

Constat log:
- Le même test montrait `handlePlay` deux fois d'affilée.
- Surtout, `video_decode_loop starting` apparaissait deux fois au démarrage.
- Ça veut dire que deux workers vidéo lisaient la même `videoPacketQueue` en parallèle.

Cause:
- `PlaybackSession.play()` est async et faisait un `await startWorkerTasksIfNeeded(...)` avant d'assigner `demuxTask`.
- Pendant cette fenêtre, un deuxième `play()` pouvait repasser le guard `demuxTask == nil`.
- Résultat: startup doublé, consommation concurrente des mêmes paquets, keyframes perdues, puis vidéo qui part de travers avant de finir vide/figée.

Correction:
- Ajout d'un verrou d'intention `playbackStartupInProgress`.
- `play()` refuse maintenant tout second lancement tant que le premier n'a pas fini d'installer les workers.
- Après `await startWorkerTasksIfNeeded(...)`, on revalide aussi la `generation` avant d'armer `watchdogTask` et `demuxTask`.
- Ça évite aussi qu'un `pause()`/`stop` pendant le startup laisse `play()` recréer des tâches zombies juste après.

But:
- garantir un seul pipeline playback actif par session,
- empêcher la double consommation de queue au démarrage,
- stabiliser le chemin VT sans rechanger de backend comme des touristes.

### 24. Ne jamais réordonner les paquets H.264/H.265 côté demux

Constat:
- Le log split VT était propre côté pacing et presque silencieux côté erreurs decode.
- Pourtant l'image repartait en pixels verts / burning.
- `FFmpegDemuxAdapter` gardait encore un buffer local et triait les paquets par `PTS` avant de les livrer.

Pourquoi c'est mauvais:
- Pour H.264/H.265 avec B-frames, l'ordre utile au décodeur est l'ordre demux/decode, pas l'ordre de présentation.
- Réordonner les paquets en `PTS` avant `VideoToolbox` revient à nourrir le décodeur avec des références dans le mauvais ordre.
- C'est exactement le genre de sabotage qui peut produire des artefacts visuels violents tout en gardant des logs "propres".

Correction:
- Suppression du reorder buffer paquet dans `FFmpegDemuxAdapter`.
- Les paquets sont maintenant yielded dans l'ordre brut de lecture FFmpeg, avec leurs `PTS/DTS` inchangés.
- Le seul endroit où un reorder a du sens reste la sortie frame du fallback software, pas l'entrée packet du décodeur.

But:
- arrêter de casser l'ordre de decode des GOP AVC/HEVC,
- laisser `VideoToolbox` voir les paquets dans l'ordre qu'il attend,
- éliminer une cause structurelle de blocs verts / smear au lieu de polir les symptômes.

### 25. Ne plus bypasser VideoToolbox par codec

Demande:
- arrêter le hardcoding "AV1/VP9 -> software direct".
- laisser le primaire VT tenter sa chance, puis fallback software seulement s'il ne sait pas suivre.

Changements:
- suppression du bypass codec dans `DefaultVideoPipeline`.
- ajout du transport `width/height` depuis le demux FFmpeg jusqu'à `DemuxedPacket`.
- `VideoToolboxDecoder` peut maintenant tenter un `CMVideoFormatDescriptionCreate(...)` générique pour `AV1` et `VP9` à partir des dimensions du stream.
- le fallback software reste le plan B si VT remonte un échec de capacité/session.

But:
- laisser le runtime décider au lieu d'un `switch` paresseux,
- permettre d'observer le vrai comportement VT sur AV1/VP9,
- préparer un fallback software plus honnête sans politique codée au marqueur.

### 26. AV1 software decode split: appliquer le BSF aussi en multi-demux

Constat log:
- En AV1 1440p split, VT est bien tenté puis échoue vite avec `sessionCreationFailed(-12906)`.
- Le fallback software FFmpeg/dav1d démarre, rend quelques secondes, puis enchaîne les `drop_invalid_packet codec=av1 status=-1094995529`.
- Ce pattern sent le flux mal préparé, pas juste "le CPU rame".

Cause probable:
- Le demux simple appliquait déjà le BSF `av1_frame_merge`.
- Le chemin `open_demux_multi` utilisé pour le split A/V ne l'appliquait pas au flux vidéo.
- En plus, le side data `AV_PKT_DATA_NEW_EXTRADATA` n'était pas propagé dans ce chemin multi.

Correction:
- ajout d'un BSF vidéo dédié au `svp_ffmpeg_multi_demuxer` pour les codecs qui en ont besoin, notamment AV1.
- application du filtre sur chaque paquet vidéo lu dans le chemin multi.
- propagation du side data `NEW_EXTRADATA` jusqu'au paquet sortant.
- retrait de l'heuristique keyframe basée sur les NAL H264/HEVC pour les autres codecs.

But:
- nourrir le decodeur software AV1 avec des paquets valides et dans le bon format,
- arrêter les rafales `INVALIDDATA` qui provoquent les freezes/reprises,
- corriger le vrai chemin split utilisé par le test, pas un cousin plus propre mais hors sujet.

- 27) 2026-03-14 4K AV1 software decode: made FFmpeg INVALIDDATA handling less trigger-happy by resetting consecutive invalid-drop streaks on accepted packets with no output, and raising the fatal streak threshold for AV1 from 8 to 32 in Sources/Decode/FFmpegVideoDecoder.swift. This avoids brief AV1 packet-corruption bursts turning into full playback resync/freeze cycles.

- 28) 2026-03-14 AV1 software reorder recovery: taught the FrameReorderBuffer in Sources/Decode/VideoDecoder.swift to detect large PTS discontinuities (>0.5s) and drop the stale prefix before the gap. This prevents old pre-stall frames from being released after decode resumes, which was causing long post-freeze catch-up drops on 4K AV1.

- 29) 2026-03-14 AV1 discontinuity smoothing: after a large PTS gap, the FrameReorderBuffer now holds recovered frames for up to 0.5s of continuous media before releasing them. This lets it discard tiny post-gap "islands" if another discontinuity follows immediately, reducing back-to-back freezes into a single cleaner jump.

- 30) 2026-03-14 AV1 discontinuity hold tuning: raised the post-gap recovery hold in Sources/Decode/VideoDecoder.swift from 0.5s to 1.25s. The prior value still allowed a short 5.539-5.873 island to leak out before a second gap at 7.007, producing two back-to-back freezes instead of one cleaner jump.

- 31) 2026-03-14 AV1 software config-change handling: FFmpegVideoDecoder now treats AV_PKT_DATA_NEW_EXTRADATA as a real decoder configuration update. It recreates/retargets the decoder using the new extradata for that packet and stops forwarding the same side data redundantly into the C bridge. This targets the deterministic 3s-7s AV1 failure window where software decode likely crossed a stream config boundary with stale decoder state.

- 32) 2026-03-14 Multi-demux side data propagation fix: FFmpegDemuxAdapter.makePacketStream() was copying only packet payload bytes from the C multi-demux bridge and silently dropping `sideData`/`sideDataType` before building `DemuxedPacket`. That meant split A/V playback could never surface `AV_PKT_DATA_NEW_EXTRADATA` to FFmpegVideoDecoder even when CShim propagated it correctly. The adapter now preserves side data for multi-input packets so AV1 software decode can finally observe real mid-stream config updates instead of debugging a lie.

- 33) 2026-03-14 Multi-demux AV1 BSF packet-loss fix: `filter_multi_video_packet_if_needed()` in Sources/Adapters/FFmpegBridge/CShim.c was mishandling `av_bsf_send_packet(...)=EAGAIN`. It drained one already-filtered packet and returned immediately without retrying the current input packet, effectively dropping video packets whenever the AV1 bitstream filter had backpressure. The logic now mirrors the single-input BSF path: drain one output, keep it aside, retry sending the same input, and only return the drained packet after the current input has actually been accepted by the BSF.
