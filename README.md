# tp-iac-regis

Depot d'infrastructure as code du TP1 (module 2). Il sert de socle "sain" :
fins de ligne normalisees, secrets tenus hors du depot, garde-fous automatiques.

## Prerequis

- Git >= 2.40
- Un shell POSIX. Sous Windows : WSL2 ou Git Bash (jamais cmd/PowerShell pour `make`).
- `pre-commit` et `gitleaks` installes (voir Demarrage).

## Demarrage

```bash
git clone <url> tp-iac-regis
cd tp-iac-regis
pre-commit install        # installe les hooks locaux
make help                 # liste les commandes disponibles
make lint                 # hygiene + lint
make secrets              # recherche de secrets dans l'historique
```

Mainteneur : Blazefive.
