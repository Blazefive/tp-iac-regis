# ADR 0001 - Un depot IaC sain par defaut

Date : 2026-07-29
Statut : accepte
Auteur : Blazefive

## Contexte
Le depot Git devient la CMDB executable du projet. Un depot mal tenu (secrets
versionnes, fins de ligne mixtes, pas de revue) est une porte d'entree.

## Decision
- Normalisation LF via `.gitattributes` des le premier commit.
- Secrets hors du depot (`.gitignore`) + detection automatique (pre-commit + gitleaks).
- Commits signes (SSH) et protection de la branche `main`.

## Consequence
Le controle local (pre-commit) est un filet ergonomique : il se contourne avec
`--no-verify`. La vraie barriere est cote serveur (CI + protection de branche).
