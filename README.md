# tp-iac-regis

Depot d'infrastructure as code de la formation.
Socle de depot sain (TP1, module 2) et deploiement Terraform sur AWS (TP2, module 3).

Convention : **le code est en anglais, la documentation en francais.** Le code se lit
par d'autres, souvent hors contexte ; les rapports sont des livrables pedagogiques.

## Prerequis

- Git >= 2.40, Terraform >= 1.10, AWS CLI v2, `jq`
- Un shell POSIX. Sous Windows : WSL2 ou Git Bash (jamais cmd/PowerShell pour `make`).
- `pre-commit` et `gitleaks` installes.

## Structure

```
docs/adr/               decisions d'architecture
docs/tp1-rapport.md     livrable module 2
docs/tp2-rapport.md     livrable module 3
envs/dev-aws/           serveur web nginx durci sur AWS (8 ressources)
Makefile                interface unique du projet
```

## TP2 — cycle complet

```bash
aws configure --profile tp2          # ou aws configure sso
ssh-keygen -t ed25519 -f ~/.ssh/tp2_ed25519 -N ""
make ip                              # votre IP publique en /32
cp envs/dev-aws/terraform.tfvars.example envs/dev-aws/terraform.tfvars
$EDITOR envs/dev-aws/terraform.tfvars    # renseigner admin_cidr

make bootstrap        # A : cree le bucket S3 d'etat et ecrit backend.hcl
make init             # A : init sur le backend S3
make plan             # B : plan -out=dev.tfplan, ne modifie rien
make apply            # B : applique exactement ce plan

make drift && make plan      # D : derive hors Terraform, puis detection
make apply && make state     # D : reconciliation, puis inspection de l'etat
```

Fin de seance, **obligatoire** — l'ordre compte, `teardown` apres `destroy` :

```bash
make destroy && make teardown && make leftovers
```

`make help` liste toutes les cibles.

## Configuration

Une seule variable est obligatoire : `admin_cidr`, votre IP publique en /32.
Toutes les autres ont un defaut, et `terraform.tfvars.example` les liste pour
donner en un fichier la surface de configuration complete de la racine.

Deux valeurs echappent a `terraform.tfvars` :

- **le nom du bucket d'etat**, parce qu'un bloc `backend` n'accepte ni variable
  ni interpolation. C'est le role de `backend.hcl` (ignore par Git, ecrit par
  `make bootstrap`) et de la configuration partielle du backend. Effet de bord
  utile : l'identifiant du compte AWS reste hors du depot public.
- **les controles de securite** — chiffrement du volume racine,
  `http_tokens = "required"`, limite de sauts des metadonnees. Ils sont ecrits en
  dur dans `main.tf`. Exposer un controle de securite en variable le rend
  optionnel, et un controle optionnel dont le defaut du fournisseur n'est pas sur
  est exactement la cause racine que le cours documente.

## Compte AWS partage

Le compte de la formation est partage entre etudiants. Deux consequences :

- la variable `project` doit contenir votre nom, sinon collision de nommage sur
  le groupe de securite et la paire de cles ;
- `make leftovers` filtre sur l'etiquette `Project` : il ne montre que **vos**
  ressources, et ne doit jamais servir a supprimer celles d'un camarade.

## Deux points a ne pas « corriger » sans lire le rapport

1. Les regles du groupe de securite sont des blocs `ingress` **en ligne**, pas des
   ressources `aws_vpc_security_group_ingress_rule`. Avec les ressources separees,
   une regle ajoutee a la main est un objet non gere : Terraform ne signale
   **aucune** derive, et la partie D devient infaisable.
2. `user_data_replace_on_change = true` est volontaire. Sans lui, modifier
   `user_data` n'a aucun effet sur une instance en cours d'execution : le plan est
   vert et la machine reste sur l'ancienne configuration.

Mainteneur : Blazefive.
