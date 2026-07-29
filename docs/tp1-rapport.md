# TP1 — Un dépôt IaC sain, de bout en bout

**Module 2 — Gestion des configurations et Git**
Auteur : Blazefive · Mastère Cybersécurité 4A · 29/07/2026

Environnement : WSL2 Ubuntu (travail dans `~`, jamais dans `/mnt/c` — leçon du module 1).

Dépôt distant **réel** : <https://github.com/Blazefive/tp-iac-regis> (privé). Les commits sont
signés en SSH et **vérifiés** sur GitHub (badge *Verified* — l'API renvoie `"verified": true,
"reason": "valid"`).

Seule limite : la **protection de branche** est démontrée **en local** (hook `pre-receive`). GitHub
réserve cette fonctionnalité aux dépôts publics ou au plan Pro pour les dépôts **privés** ; l'API
renvoie `403 « Upgrade to GitHub Pro or make this repository public »`. On garde donc le dépôt privé
(conforme au TP) et on démontre le mécanisme localement — c'est une vraie contrainte de plan, pas un
raccourci.

Dépôt local de travail : `~/tp-iac-regis`

---

## Ce que j'ai fait

### Partie A — Initialisation
Dépôt `tp-iac-regis` (branche `main`) avec, à la racine : `.gitattributes` (LF), `.gitignore`
(Terraform + secrets), `.editorconfig`, `README.md` (titre + Prérequis + Démarrage) et un
`Makefile`. Trois commits séparés, en *Conventional Commits* :

```
* chore: ajoute le Makefile, interface unique du projet
* docs: ajoute le README (prérequis + démarrage)
* chore: initialise le socle du dépôt (gitattributes, gitignore, editorconfig)
```

`git show --stat HEAD` confirme que chaque commit ne contient que ce qu'il annonce (le dernier =
`Makefile` seul). Le `Makefile` déclare `SHELL := /bin/bash` et `.SHELLFLAGS := -eu -o pipefail -c`,
et sa cible `help` auto-documentée fonctionne :

```
help     affiche cette aide
lint     hygiene + lint : rejoue les hooks pre-commit sur tout le depot
secrets  scan des secrets sur tout l historique (gitleaks)
clean    supprime les artefacts locaux (sans echouer si absents)
```

### Partie B — Garde-fous
`.pre-commit-config.yaml` avec le minimum demandé : `trailing-whitespace`, `end-of-file-fixer`,
`check-yaml`, `mixed-line-ending (--fix=lf)`, `detect-private-key` et `gitleaks`. `pre-commit install`
puis `pre-commit run --all-files` → tout passe. Cible `secrets` ajoutée au `Makefile`
(`gitleaks detect --source . --verbose`).

### Partie C — Provoquer la fuite
`config/app.env` contenant une fausse clé de forme AWS.

- **Commit normal → BLOQUÉ** par le hook (message exact) :

```
gitleaks (scan des secrets stagés)...................................Failed
- hook id: gitleaks
- exit code: 1
Finding:  AWS_ACCESS_KEY_ID=AKIA7QK9…3NLU   (masquée ici)
RuleID:   aws-access-token
File:     config/app.env
...
leaks found: 2
```

- **Contournement `--no-verify`** → le commit passe (exit 0).
- **`make secrets`** → gitleaks scanne l'historique et retrouve le secret (`leaks found: 2`,
  `make: *** [secrets] Error 1`).
- **Purge `git filter-repo --path config/app.env --invert-paths`** → `git log --all --full-history --
  config/app.env` ne renvoie plus **aucune** ligne, le dossier `config/` a disparu.

### Partie D — Signature et protection
Signature SSH configurée (`gpg.format ssh`, `commit.gpgsign true`, `allowedSignersFile`). Commit
signé de l'ADR :

```
git verify-commit HEAD
Good "git" signature for 116870999+Blazefive@users.noreply.github.com with ED25519 key (empreinte SSH publique)
```

Protection de la branche `main` (hook `pre-receive`) → **push direct refusé** :

```
remote: [protection] push direct sur 'main' interdit - passez par une pull request.
 ! [remote rejected] main -> main (pre-receive hook declined)
error: failed to push some refs
```

> **Note honnête (découverte pendant le TP).** La clé d'exemple **officielle** d'AWS de l'énoncé
> (`AKIAIOSFODNN7EXAMPLE` / `wJalrXUtn…EXAMPLEKEY`) n'est **pas** détectée : la configuration par
> défaut de gitleaks l'*allowliste* (stopword des exemples de documentation, pour éviter les faux
> positifs). Pour démontrer réellement le blocage, j'ai donc utilisé une fausse clé de **même forme
> mais non canonique** (`AKIA7QK9…3NLU`, masquée). C'est un rappel utile : un scanner de secrets a des
> exceptions, et « pas d'alerte » ne veut pas dire « pas de secret ».

---

## Réponses aux quatre questions du livrable

### 1. Pourquoi `--no-verify` fonctionne-t-il, et quelle est la seule parade réellement efficace ?

Un hook `pre-commit` s'exécute **sur le poste du développeur**, depuis `.git/hooks/`. `git commit
--no-verify` (ou `-n`) demande simplement à Git de **sauter** ces hooks. Le contrôle vit donc chez
celui qu'il est censé contraindre : il peut toujours le désactiver. Je l'ai vérifié — le commit
bloqué (exit 1) est passé sans problème avec `--no-verify` (exit 0). C'est un **filet ergonomique**,
pas une barrière.

La **seule parade réellement efficace** est de rejouer **les mêmes vérifications côté serveur**,
dans le pipeline de CI, et d'ajouter une **protection de branche** qui rend leur succès obligatoire
pour fusionner. C'est le principe de **médiation complète** : un contrôle qu'on peut contourner par
un autre chemin ne protège pas. Dans ce TP, c'est exactement ce que fait le refus de push direct
sur `main`.

### 2. Le secret purgé était-il présent sur le serveur distant ? Qu'auriez-vous fait en premier s'il avait été réel ?

**Dans ce TP : non.** Le commit fuité (`chore: config`, via `--no-verify`) est resté **local** : il
n'a jamais été poussé sur `origin` (les push des parties A et B ne contenaient pas `config/app.env`,
créé seulement en partie C). `origin` n'a donc jamais reçu le blob — et de toute façon les valeurs
étaient de fausses clés.

**Mais si le secret avait été réel et poussé**, il vivrait sur le serveur, dans **toutes les copies
clonées, les forks**, et resterait atteignable par l'URL de commit même après suppression de la
branche. Réécrire l'historique n'est alors que du **nettoyage, pas de la remédiation**.

La **première action** aurait été de **révoquer immédiatement** le secret chez son émetteur (console
AWS…) : trente secondes, et la fuite est neutralisée. Ensuite seulement : générer un nouveau secret
dans un coffre, chercher les traces d'usage (CloudTrail / journaux d'audit), puis éventuellement
réécrire l'historique. Réécrire **avant** de révoquer donne un faux sentiment de sécurité : les
moissonneurs scannent les dépôts publics en continu, le délai entre publication et exploitation se
compte en minutes (cf. EmeraldWhale, campagne `.env` d'Unit 42).

### 3. En quoi la mutabilité des tags Git explique-t-elle l'incident tj-actions/changed-files ?

Un tag Git est un **pointeur nommé mutable** : rien n'empêche `git tag -f v45 <autre-commit>` puis
`git push --force --tags`. Le **nom reste le même**, le **contenu pointé change**.

Le 14 mars 2025 (CVE-2025-30066), un attaquant ayant compromis le PAT du bot du projet a **réécrit
tous les tags de version** (de `v1.0.0` à `v45`) pour qu'ils pointent vers un **unique commit
malveillant**. Tous les workflows qui référençaient l'action par son tag
(`uses: tj-actions/changed-files@v45`) ont exécuté le code malveillant **sans qu'une seule ligne de
leur propre dépôt ne change**. La charge dumpait la mémoire du runner (`/proc/[pid]/mem`) et
recrachait les secrets, encodés deux fois en base64, dans les logs du workflow.

Principe généralisable : **un nom lisible est un pointeur mutable ; une empreinte de contenu est une
identité.** La parade totale : épingler par **SHA de commit complet**
(`uses: org/action@<sha40>`), qui est immuable.

### 4. Trois éléments du dépôt relevant de la gestion de configuration au sens ITIL

Au sens ITIL, « gestion de configuration » = gouvernance : identifier, tracer et **contrôler** les
éléments de configuration et leurs relations (audit, baseline, gestion des changements). Dans le
dépôt :

1. **Les commits eux-mêmes** (message *Conventional Commits* + auteur + date), et surtout le commit
   **signé** : c'est la **piste d'audit** et la **ligne de base (baseline) infalsifiable** — chaque
   commit est identifié par une empreinte cryptographique, l'état de référence vers lequel on peut
   revenir.
2. **Le `README.md` et l'ADR `docs/adr/0001`** : la documentation des éléments de configuration et
   des décisions (le *quoi*, le *pourquoi*, le *qui*) — l'équivalent documentaire d'une **CMDB**.
3. **La protection de branche + la revue obligatoire** : le **processus de contrôle des changements**
   (change management) — qui a le droit de modifier quoi, et sous quelle validation.

(On pourrait aussi citer le `.gitignore` comme politique de ce qui ne doit jamais être enregistré,
ou un futur `.terraform.lock.hcl` comme baseline des versions de providers.)

---

## Ce que je retiens

- `pre-commit` protège le confort, pas la production : la vraie barrière est en CI + protection de
  branche.
- Révoquer d'abord, réécrire l'historique ensuite. Jamais l'inverse.
- Un tag, une branche, `:latest` : des noms mutables. Une empreinte (SHA, digest) : une identité.
- Un secret commité reste dans les objets Git par son empreinte, même après `git rm`.
