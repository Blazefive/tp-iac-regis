# TP1 — Un dépôt IaC sain, de bout en bout

**Module 2 — Gestion des configurations et Git** · Blazefive · 29/07/2026

Dépôt : <https://github.com/Blazefive/tp-iac-regis> — commits signés (SSH) et *Verified*,
branche `main` protégée. Réalisé sous WSL2 Ubuntu.

## Déroulé

**A. Initialisation.** `.gitattributes` (LF), `.gitignore` (Terraform + secrets), `.editorconfig`,
`README.md`, `Makefile` (`SHELL := /bin/bash`, `.SHELLFLAGS := -eu -o pipefail -c`, cible `help` par
défaut auto-documentée). Trois commits séparés en Conventional Commits.

**B. Garde-fous.** `.pre-commit-config.yaml` : `trailing-whitespace`, `end-of-file-fixer`,
`check-yaml`, `mixed-line-ending --fix=lf`, `detect-private-key`, `gitleaks`. `pre-commit install`
puis `run --all-files` : tout passe. Cible `secrets` = `gitleaks detect --source . --verbose`.

**C. Fuite provoquée.** Ajout d'un `config/app.env` contenant une clé de forme AWS.
`git commit` → **bloqué** par gitleaks (`exit 1`). `git commit --no-verify` → passe (contourne le
hook). `make secrets` → gitleaks retrouve la clé dans l'historique. Purge :
`git filter-repo --path config/app.env --invert-paths`, après quoi
`git log --all --full-history -- config/app.env` ne renvoie plus rien.
> Nuance observée : la clé d'exemple officielle publiée par AWS dans sa documentation est allowlistée
> par gitleaks ; il faut une fausse clé non canonique pour voir la détection se déclencher.

**D. Signature + protection.** Signature SSH (`gpg.format ssh`, `commit.gpgsign true`).
`git verify-commit HEAD` → `Good "git" signature`. Protection de `main` : push direct interdit, une
revue obligatoire, force-push interdit. Un push direct est refusé :
```
remote: error: GH006: Protected branch update failed for refs/heads/main.
remote: - Changes must be made through a pull request.
```

## Réponses

**1. Pourquoi `--no-verify` fonctionne, et la seule parade efficace ?**
Les hooks pre-commit s'exécutent côté client ; `--no-verify` demande simplement à Git de les sauter.
C'est un filet ergonomique, pas une barrière. La seule parade efficace : rejouer les mêmes contrôles
**côté serveur** (CI), avec une **protection de branche** qui rend leur succès obligatoire pour
fusionner — le principe de médiation complète.

**2. Le secret purgé était-il sur le serveur distant ? Que faire en premier s'il était réel ?**
Non : le commit fuité n'a jamais été poussé avant la purge. S'il avait été réel, la première action
est de **révoquer immédiatement** la clé chez le fournisseur (AWS IAM), puis de la remplacer, de
chercher les traces d'usage, et seulement ensuite de réécrire l'historique. Réécrire avant de
révoquer donne un faux sentiment de sécurité : les dépôts publics sont scannés en continu.

**3. En quoi la mutabilité des tags explique-t-elle l'incident tj-actions/changed-files ?**
Un tag Git est un pointeur **mutable** (`git tag -f`). Dans l'incident (CVE-2025-30066), les tags de
version ont été réécrits pour pointer vers un commit malveillant : tous les workflows en `@vX` ont
exécuté ce code sans qu'une ligne de leur dépôt ne change. Parade : épingler par **SHA de commit**,
qui est immuable.

**4. Trois éléments du dépôt relevant de la gestion de configuration (sens ITIL) ?**
- **Les commits signés** : piste d'audit et ligne de base (baseline) infalsifiable, chacun identifié
  par une empreinte.
- **README + ADR** : documentation des éléments et des décisions — l'équivalent d'une CMDB.
- **Protection de branche + revue obligatoire** : le contrôle des changements (change management).

## À retenir
- pre-commit protège le confort, pas la prod : la barrière est en CI + protection de branche.
- Révoquer d'abord, réécrire l'historique ensuite. Jamais l'inverse.
- Un nom (tag, branche, `:latest`) est mutable ; une empreinte (SHA, digest) est une identité.
- Un secret commité reste dans les objets Git même après `git rm`.
