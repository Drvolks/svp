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
