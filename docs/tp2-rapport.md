# TP2 — Déploiement sécurisé sur AWS, état distant et détection de dérive

**Module 3 — IaC & Terraform** · Blazefive · 30/07/2026
Terraform v1.15.8, provider `hashicorp/aws` v6.57.1, région `eu-west-3`, WSL2 Ubuntu 24.04.
Dépôt : <https://github.com/Blazefive/tp-iac-regis> — reprise du socle du TP1.

## Périmètre

Mené en **plan-only**, **AWS seul**. Ce qui a réellement tourné :

| | Statut |
|---|---|
| A — code du backend S3 + script de création du bucket | écrits, **non exécutés** |
| A — `init`, verrou de provider | **exécuté** — `.terraform.lock.hcl` versionné (aws v6.57.1, signé HashiCorp) |
| B — code, `fmt`, `validate`, `plan -out` | **exécuté** — `Plan: 8 to add, 0 to change, 0 to destroy` |
| B — `apply`, vérification HTTP | **non exécuté** |
| C — Azure | **non traitée** : aucune souscription, `az` absent du poste |
| D — dérive réelle, inspection du `tfstate`, `destroy` | **non exécutés** — procédure ci-dessous |

Aucune ressource n'a été créée : CloudTrail ne montre aucun événement d'écriture pour l'utilisateur
`regis`. Le `plan` n'a émis que des appels de lecture (`DescribeImages`, `GetCallerIdentity`) — ce qui
ne veut pas dire que `plan` est inoffensif, voir « À retenir ».

> **Le compte AWS de la formation est partagé par toute la promotion.** `list-buckets` renvoie neuf
> buckets d'état qui ne sont pas les miens — huit portent un prénom d'étudiant — plus la paire de clés
> du formateur. J'ai relevé le fait ; je n'ai lu aucun de ces états. C'est le point de sécurité le
> plus intéressant du TP, voir Partie A.

## Partie A — Socle et état distant

```hcl
# Configuration PARTIELLE : un bloc backend n'accepte ni variable ni
# interpolation, le nom du bucket est donc fourni à l'initialisation.
backend "s3" {
  key          = "dev-aws/terraform.tfstate"
  region       = "eu-west-3"   # doit être un littéral
  encrypt      = true          # chiffrement imposé à l'écriture
  use_lockfile = true          # verrouillage natif S3 — vaut false PAR DÉFAUT
}
```
```bash
terraform init -backend-config=backend.hcl    # bucket = "<projet>-tfstate-<compte>"
```

`use_lockfile` remplace la table DynamoDB des tutoriels antérieurs à 2025 (introduit en 1.10.0, GA en
1.11.0, DynamoDB déprécié). **Il vaut `false` par défaut** : sans cette ligne, aucun verrou, et deux
`apply` simultanés corrompent l'état. Rien ne le signale.

La configuration partielle n'est pas un raffinement : c'est le **seul** mécanisme disponible pour
sortir le nom du bucket du code, puisqu'un bloc `backend` est évalué avant les variables. Effet de
bord utile ici — l'identifiant du compte AWS, que le nom du bucket contient, reste hors du dépôt
public. `backend.hcl` est ignoré par Git, `backend.hcl.example` documente le format, et
`make bootstrap` écrit le fichier réel.

Le bucket est créé **hors Terraform** (`make bootstrap`) : une racine ne peut pas gérer le backend
dont elle se sert. Trois réglages, exactement ceux de la consigne — versioning, Block Public Access
(4 interrupteurs), chiffrement par défaut SSE-S3 + Bucket Key.

SSE-S3 et non SSE-KMS avec clé gérée par le client : une CMK coûte ~1 USD/mois et sa suppression
impose un délai de 7 à 30 jours, incompatible avec un TP. C'est le seul écart assumé au cours.

`init` vérifié : `.terraform.lock.hcl` créé et **versionné** ; `.terraform/`, `terraform.tfvars` et
`*.tfplan` ignorés (`git check-ignore` sur chacun). J'ai ajouté `*.tfplan` au `.gitignore` du TP1 :
le plan binaire contient toutes les valeurs planifiées, HashiCorp le met au même niveau de
sensibilité que l'état.

**La faille structurelle de ce compte.** Mon utilisateur IAM `regis` — clé d'accès longue durée, pas
de SSO — peut lister les buckets de tout le compte, donc voir les états de mes camarades. Chaque
bucket est bien durci *individuellement*, mais durcir un bucket ne protège pas contre un principal
légitime du compte. Le contrôle manquant est **IAM**, pas S3 : il faudrait une politique restreignant
`s3:*` sur `tp-iac-<etudiant>-tfstate-*` au seul principal correspondant, ou un compte par étudiant.
C'est l'exigence « accès réservé aux rôles de déploiement » du cours — la seule des cinq qu'un bucket
parfaitement configuré ne peut pas satisfaire seul.

## Partie B — Déploiement AWS

Huit ressources, une seule racine, aucun module : `aws_vpc` → `aws_internet_gateway` →
`aws_subnet` → `aws_route_table` + association → `aws_security_group` → `aws_key_pair` →
`aws_instance`.

```
Plan: 8 to add, 0 to change, 0 to destroy.
```

Durcissement relu dans le JSON du plan, valeurs effectives :

| Contrôle | Valeur | Pourquoi |
|---|---|---|
| `http_tokens` | `required` | IMDSv2 imposé — **aucune valeur par défaut sûre** dans le provider |
| `http_put_response_hop_limit` | `1` | bloque le relais via reverse proxy ou conteneur mal isolé |
| `root_block_device.encrypted` | `true` | chiffrement au repos explicite |
| SSH 22/tcp | `<mon-IP>/32` | jamais `0.0.0.0/0` — deux blocs `validation` l'interdisent |
| HTTP 80/tcp | `0.0.0.0/0` | le service est public, c'est l'objectif |
| `user_data_replace_on_change` | `true` | voir ci-dessous |

Toute la configuration est paramétrable et documentée dans `terraform.tfvars.example` — sauf trois
lignes, laissées **en dur volontairement** : le chiffrement du volume racine, `http_tokens` et la
limite de sauts. Exposer un contrôle de sécurité en variable le rend optionnel ; or la thèse du cours
est précisément que la cause racine des mauvaises configurations n'est pas l'erreur d'écriture, mais
le fait que les arguments de sécurité soient optionnels et leurs défauts non sûrs. Les rendre
configurables aurait reproduit le défaut qu'on cherche à corriger.

AMI résolue : `ami-0c1002cdaa7a0954f`
(`ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-20260714`, Canonical). `t2.micro` plutôt
que `t3.micro` : c'est le seul type couvert par les 750 h/mois du palier gratuit historique.

Trois décisions non triviales, qui sont l'essentiel de ce que j'ai appris :

**1. Règles de pare-feu en blocs `ingress` *en ligne*, pas en ressources séparées.** Avec
`aws_vpc_security_group_ingress_rule`, une règle ajoutée à la main est un objet **non géré** :
Terraform ne la voit pas et ne signale **aucune** dérive. Les blocs en ligne donnent à Terraform
l'ensemble complet des règles, donc la détection. La partie D est infaisable avec l'écriture
« moderne » — ici le choix de style détermine la capacité de détection, ce n'est pas cosmétique.

**2. `user_data_replace_on_change = true`.** Sans cette ligne, modifier `user_data` ne change *rien*
sur une instance qui tourne : le script ne s'exécute qu'au premier démarrage. Terraform afficherait
un plan vert pendant que la machine reste sur l'ancienne configuration — une dérive invisible,
introduite par Terraform lui-même. À `true`, l'instance est remplacée : modèle immuable.

**3. Un bloc `check`.** Assertion rejouée à chaque `plan` et `apply` après rafraîchissement : le port
22 ne doit jamais être joignable depuis `0.0.0.0/0`. Sur le plan initial elle ne produit **aucun
avertissement** — les valeurs ne sont pas encore connues, Terraform la saute silencieusement. Son
intérêt est post-`apply` : un détecteur de dérive permanent, qui avertit sans bloquer.

## Partie D — Dérive : procédure et interprétation

Non exécutée faute d'`apply`. La séquence est scriptée dans le `Makefile` :

```bash
make drift   # authorize-security-group-ingress --port 22 --cidr 0.0.0.0/0
make plan    # détection
make apply   # réconciliation
make state   # inspection du tfstate
```

`make drift` lit l'ID du groupe dans la sortie Terraform (`output -raw security_group_id`), pas dans
la console : la source de vérité reste le projet.

Ce que le `plan` montrera, et son interprétation :

1. `~ update in-place` sur `aws_security_group.web`, le jeu `ingress` passant de deux à trois règles,
   la troisième étant `22/tcp depuis 0.0.0.0/0`. Le rafraîchissement a constaté que la réalité ne
   correspondait plus à l'état ; Terraform propose de la ramener vers la configuration, qui reste la
   source de vérité.
2. Le bloc `check` passe en **Warning** : les valeurs sont désormais connues et l'assertion échoue.
   C'est l'avertissement qui compte, plus que le diff — il nomme le problème de sécurité au lieu de
   décrire un écart d'attributs.
3. `apply` révoque la règle surnuméraire. **La modification manuelle est silencieusement écrasée** —
   comportement voulu, et c'est aussi pourquoi une correction d'urgence faite en console est perdue au
   déploiement suivant si elle n'est pas reportée dans le code.
4. Aucune trace de *qui* a ouvert le port : CloudTrail le sait, Terraform non. La dérive est détectée
   et corrigée, elle n'est pas attribuée.

## Les trois informations sensibles de l'état — et le contrôle qui le protège

Pas d'`apply`, donc pas de `tfstate`. Les trois éléments ci-dessous sont **vérifiés dans le fichier
de plan réellement produit** (`dev.tfplan`, 13 458 octets), qui contient les mêmes valeurs et se
protège de la même façon.

**1. Le script `user_data` en clair.** Lisible intégralement
(`jq '.resource_changes[] | select(.address=="aws_instance.web") | .change.after.user_data'`). Ici
une page nginx anodine ; en production ce script porte régulièrement jetons d'enrôlement,
identifiants de dépôt privé et URL internes. Rien ne les distingue du reste.

**2. La topologie réseau et les règles de pare-feu exactes.** `10.20.0.0/16`, `10.20.1.0/24`,
`eu-west-3a`, plus le jeu de règles complet — donc la surface d'attaque énumérée, sans avoir à scanner.

**3. Mon adresse IP publique personnelle, `<mon-IP>/32`.** Conséquence directe de la bonne pratique
« SSH restreint à votre IP » : la mesure de sécurité inscrit une **donnée personnelle** dans l'état,
que le versioning du bucket conserve indéfiniment. Elle est masquée dans ce rapport pour la même
raison — le dépôt est public.

**Contrôles qui protègent ce fichier dans ma configuration :**

| Niveau | Contrôle |
|---|---|
| Backend | `encrypt = true`, `use_lockfile = true`, clé dédiée par racine |
| Bucket | versioning, Block Public Access ×4, chiffrement par défaut |
| Dépôt | `.gitignore` : `*.tfstate*`, `*.tfplan`, `backend.hcl` ; `gitleaks` en pre-commit (TP1) |
| **Manquant** | **politique IAM par étudiant** — voir Partie A, c'est le trou réel |

La parade structurelle, non nécessaire ici puisqu'aucune ressource ne produit de secret : les valeurs
**éphémères** (1.10) et les attributs **en écriture seule** `*_wo` (1.11), qui empêchent le secret
d'entrer dans l'état au lieu de tenter de l'y protéger.

## Tableau comparatif AWS ↔ Azure

Colonne AWS : ce que j'ai écrit. Colonne Azure : l'équivalent qu'il aurait fallu écrire.

| Rôle | AWS (écrit) | Azure (équivalent) |
|---|---|---|
| Groupement logique | *implicite : le VPC* | `azurerm_resource_group` |
| Réseau | `aws_vpc` — `10.20.0.0/16` | `azurerm_virtual_network` — `address_space` |
| Sous-réseau | `aws_subnet` — **une seule zone** | `azurerm_subnet` — peut couvrir plusieurs zones |
| Sortie Internet | `aws_internet_gateway` + `aws_route_table` + association | *implicite* — routage système |
| Pare-feu | `aws_security_group` (`ingress`/`egress`) | `azurerm_network_security_group` (`security_rule` + `priority`) |
| Rattachement du pare-feu | attribut `vpc_security_group_ids` | ressource dédiée `…_interface_security_group_association` |
| Adresse publique | attribut `map_public_ip_on_launch` | ressource dédiée `azurerm_public_ip` |
| Carte réseau | *implicite* | ressource dédiée `azurerm_network_interface` |
| Machine | `aws_instance` — `t2.micro` | `azurerm_linux_virtual_machine` — `Standard_B2ats_v2` |
| Image | `data.aws_ami` + filtre | bloc `source_image_reference` |
| Clé SSH | `aws_key_pair` + `key_name` | `admin_ssh_key` + `disable_password_authentication` |
| Amorçage | `user_data` (texte) | `custom_data` (**`base64encode()` obligatoire**) |
| Disque chiffré | `root_block_device.encrypted = true` | chiffré par défaut au niveau plateforme |
| Métadonnées durcies | `metadata_options.http_tokens = "required"` | **pas d'équivalent** — l'IMDS Azure exige déjà un en-tête `Metadata: true` |
| État | bucket S3 + `use_lockfile` | Storage Account / conteneur blob + bail (*lease*) |

Trois différences de **modèle**, pas de nom : Azure exige un groupe de ressources et matérialise NIC
et IP publique en ressources distinctes (plus verbeux, mais le cycle de vie de l'IP est découplé de
celui de la VM) ; le sous-réseau AWS est mono-zone, donc la haute disponibilité s'écrit dans la
topologie côté AWS et dans la ressource côté Azure ; le durcissement IMDS n'a pas d'équivalent Azure
parce que le défaut y est déjà sûr. Traduire n'est jamais renommer.

## Question de fond — IMDSv2 et Capital One (mars 2019)

Cela aurait **arrêté la chaîne** : la primitive SSRF n'émettait que des `GET` sans en-tête
personnalisé, elle n'aurait pas pu forger le `PUT` porteur de `X-aws-ec2-metadata-token-ttl-seconds`
exigé pour obtenir un jeton — donc pas d'identifiants du rôle du WAF, donc pas de `s3 sync` — et le
*hop limit* à 1 aurait bloqué tout relais.
Cela n'aurait **rien changé** à trois choses : IMDSv2 n'existait pas (annoncé le 19 novembre 2019,
huit mois *après* l'intrusion) ; le rôle du WAF restait sur-privilégié — `s3:ListAllMyBuckets` n'a
aucune raison d'y figurer, et le moindre privilège était la seule défense disponible à l'époque,
comme l'a retenu l'OCC en sanctionnant l'absence d'évaluation de risque avant migration (80 M$) ;
et les quatre mois de présence non détectée relèvent de la journalisation, pas des métadonnées.

## Facturation et destruction

Pas de capture de la page de facturation : **rien n'a été appliqué**, donc rien à détruire. La preuve
équivalente est `make leftovers`, vide — inventaire filtré sur l'étiquette `Project`.

Deux remarques que la consigne n'anticipe pas. D'abord, sur un compte **partagé**, une capture de la
page de facturation ne prouve rien de *ma* propreté : elle agrège la dépense de toute la promotion.
Seul l'inventaire filtré par étiquette est une preuve individuelle — ce qui donne à l'étiquetage
systématique une seconde justification, comptable après l'inventaire. Ensuite, la recherche non
filtrée révèle une instance `t2.micro` **en cours d'exécution** et trois VPC hors VPC par défaut qui
ne m'appartiennent pas : quelqu'un a oublié un `destroy`. Je n'y touche pas.

## À retenir

- `use_lockfile` vaut **`false` par défaut**. Un backend S3 sans cette ligne est un backend sans
  verrou, et rien ne le signale.
- **Le style d'écriture détermine la capacité de détection** : règles de pare-feu en ligne → dérive
  détectée ; ressources de règles séparées → règle manuelle invisible.
- Un bucket parfaitement durci ne protège pas d'un principal légitime du compte. Dans un compte
  partagé, le contrôle qui manque est **IAM**, et aucun réglage S3 ne le remplace.
- `sensitive = true` ne concerne que l'affichage : ni le JSON (`terraform show -json`), ni l'état.
- Le **fichier de plan** est aussi sensible que l'état : mêmes valeurs, même traitement,
  `.gitignore` compris.
- `user_data` sans `user_data_replace_on_change` produit une dérive silencieuse **créée par
  Terraform** : plan vert, machine inchangée.
- `plan` n'est pas en lecture seule (CICD-SEC-04) : providers exécutés localement, data sources
  `external`/`http`, provisioners. Ici les appels étaient en lecture, mais c'est une propriété du
  code exécuté, pas de la commande.
- IMDSv2 aurait cassé la chaîne Capital One sans corriger sa cause racine : un rôle IAM
  sur-privilégié. Les deux contrôles ne se substituent pas.
