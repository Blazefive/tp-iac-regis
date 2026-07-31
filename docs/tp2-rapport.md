# Devoir final — Pipeline CI/CD : validation, provisionnement, configuration

**Module 3 — IaC & Terraform** · Blazefive · 31/07/2026
Terraform 1.15.8 · AWS provider 6.57.1 · ansible-core · tflint 0.64.0 · trivy 0.72.0 · région `eu-west-3`
Dépôt : <https://github.com/Blazefive/tp-iac-regis> — pipeline : `.github/workflows/pipeline.yml`

## Résultat

La chaîne complète s'exécute sur GitHub Actions sans aucune intervention entre les étapes.

**Run `30618245903`** — toutes les étapes en `success` :

| Étape | Commande | Ce qu'elle fait |
|---|---|---|
| **1** | `make fmt`, `make tflint`, `make trivy` | valide le code d'infrastructure |
| **2** | `make init`, `make apply` | crée l'EC2, **uniquement si l'étape 1 est verte** |
| **3** | `make inventory` | lit `terraform output -raw instance_public_ip` et écrit l'inventaire Ansible |
| **4** | `make configure` | joue `ansible-playbook` sur cette adresse |

Puis nettoyage : règle SSH temporaire révoquée, instance détruite, règles de pare-feu restantes affichées.

**Run `30617905792`** — la démonstration inverse, et elle vaut autant. `make init` échoue ; `make apply`,
`make inventory` et `make configure` sont tous **`skipped`**. Aucune ressource créée. La condition de
l'étape 2 a donc été observée dans les deux sens, pas seulement décrite.

## Déclencheur retenu

`workflow_dispatch` pour la chaîne complète, `pull_request` pour la seule étape 1.

Le dépôt est **public**. Un déclencheur automatique sur `push` exposerait le pipeline à toute pull
request, et `terraform plan` **n'est pas une opération en lecture seule** — provisioners `local-exec`,
data sources `external` et `http`, provider malveillant s'exécutent tous sur le runner. C'est le risque
CICD-SEC-04 de l'OWASP, et Pen Test Partners a montré qu'un jeton n'ayant que la permission « plan »
suffit à extraire les identifiants AWS d'un runner.

Le job de validation tourne donc sur chaque pull request, **sans aucun identifiant**, et le job de
déploiement est réservé au déclenchement manuel.

## Étape 1 — Validation du code d'infrastructure

Trois portes, dans l'ordre, chacune échouant sur un code de retour non nul.

### Ce que les scans ont réellement trouvé

**`tflint`** — `variable "vpc_cidr" is declared but not used`. Séquelle du passage du VPC en data
source : la variable n'avait plus de lecteur. Supprimée. C'est précisément l'intérêt d'un linter face à
un simple `terraform validate`, qui l'aurait acceptée sans rien dire.

**`trivy`** — deux constats :

- **AWS-0104 (CRITICAL)** — égress totalement ouvert. **Corrigé** : au lieu de `protocol = "-1"` sur
  tous les ports, l'instance ne sort plus que sur 443, 80, 53/udp, 53/tcp et 123/udp. Une machine qui
  ne joint que ses dépôts, le DNS et l'heure est un mauvais point d'appui : plus de port sortant
  arbitraire pour un reverse shell, plus d'exfiltration sur un port haut au hasard.
- **AWS-0164 (HIGH)** — le sous-réseau attribue une IP publique. Inhérent : la machine sert une
  application publique.

### Les exceptions sont dans le code, pas dans un fichier à part

Ce qui reste est assumé par des commentaires `#trivy:ignore:` **avec justification et date
d'expiration**, placés au-dessus de la ressource concernée :

```hcl
#trivy:ignore:AWS-0104:exp:2026-12-31
resource "aws_security_group" "web" {
```

Les ports sont déjà resserrés ; ce qui subsiste est la **destination**, et aucun miroir Ubuntu ne
publie de plage d'adresses stable. Fermer proprement demanderait un mandataire sortant ou des points
de terminaison VPC — la bonne réponse en production, hors périmètre ici. L'échéance est délibérée :
une dérogation sans date est un trou permanent que personne ne relit.

### Un piège de trivy qui aurait rendu la porte rouge sans raison

Trivy annonçait le type `terraformplan-snapshot` : il avait détecté un `dev.tfplan` laissé par un essai
et scannait cet instantané **au lieu du HCL**. Dans ce mode, les commentaires `#trivy:ignore:` — qui
vivent dans le HCL — ne s'appliquent plus, et les exceptions déjà justifiées ressortaient comme des
échecs. La cible `make trivy` exclut donc `.terraform` et `*.tfplan`, et le commentaire l'explique sur
place.

## Étape 2 — Provisionnement conditionnel

**La condition est posée deux fois, volontairement.**

```yaml
deploy:
  needs: validate            # le job ne démarre pas si une porte est rouge
```

```make
apply: verify                # make apply rejoue fmt, tflint et trivy avant AWS
verify: fmt tflint trivy
```

Le premier garde-fou vit dans le graphe de jobs GitHub, le second dans le Makefile. Sans le second, la
règle ne vaudrait que dans la CI : un `make apply` lancé depuis un poste de travail contournerait la
validation. **Une propriété de sûreté qui n'existe que dans un environnement n'est pas une propriété
du code.**

Vérifié en cassant volontairement le formatage : `make apply` s'arrête sur `fmt`, sort en code 2,
Terraform n'est jamais appelé.

## Étape 3 — Adresse IP et inventaire

```make
ip="$(terraform -chdir=envs/dev-aws output -raw instance_public_ip)"
```

La sortie `instance_public_ip` a été ajoutée pour ça : `public_url` renvoie une URL, pas une adresse
exploitable par un inventaire. Le fichier produit :

```ini
[web]
aws-web-01 ansible_host=<ip>

[web:vars]
ansible_user=ubuntu
```

La cible apprend aussi la **clé d'hôte** de la machine avec `ssh-keyscan`, ce qui permet de garder
`host_key_checking = True` dans `ansible.cfg`. La solution courante — désactiver la vérification —
transforme chaque exécution en homme-du-milieu accepté d'avance.

L'inventaire est **ignoré par Git** : il est réécrit à chaque exécution depuis l'état réel.

## Étape 4 — Configuration par Ansible

`make configure` attend que SSH réponde, puis joue le playbook sur l'adresse de l'inventaire. Le
playbook déployé installe nginx, un service de jeu multijoueur en Python derrière un mandataire
WebSocket, et vérifie son propre travail : les fichiers sont servis, le code du serveur **n'est pas**
accessible en HTTP, et deux clients ouverts simultanément atterrissent bien dans la même salle sur des
couleurs opposées.

## Sécurité du pipeline

| Mesure | Pourquoi |
|---|---|
| `pull_request`, **jamais** `pull_request_target` | la seconde forme exécute le code de la PR **avec** les secrets |
| Job `deploy` réservé à `workflow_dispatch` | exige le droit d'écriture : aucun visiteur ne peut le lancer |
| Actions épinglées par **empreinte de commit** | un tag est mutable — c'est ce qui a fait marcher CVE-2025-30066 sur `tj-actions/changed-files` |
| `permissions: contents: read` | le `GITHUB_TOKEN` ne peut rien écrire |
| Règle SSH **temporaire** pour la seule IP du runner | les runners ont des adresses dynamiques ; ouvrir 22 au monde annulerait tout l'exercice |
| Révocation dans une étape `if: always()` | sans elle, une règle s'accumulerait à chaque exécution, y compris après un échec |
| Clé publique **dérivée** de la privée | un seul secret, donc aucune dérive possible entre les deux moitiés |
| Secrets hors du dépôt | `terraform.tfvars`, `backend.hcl` et l'inventaire sont ignorés ; `gitleaks` ne trouve rien sur tout l'historique |

**La faiblesse assumée : l'OIDC est impossible.** La bonne pratique est un rôle IAM avec relation de
confiance sur `token.actions.githubusercontent.com`, sans aucune clé stockée. L'utilisateur IAM de ce
TP n'a **aucune permission IAM** — `iam:ListOpenIDConnectProviders` est refusé — donc ni fournisseur
OIDC ni rôle ne peuvent être créés. Il reste des clés d'accès longue durée en secrets GitHub. Le
correctif n'est pas technique : il faut demander un rôle, puis supprimer ces deux secrets.

**Un accès à connaître** : `borisrosedev` dispose du droit d'écriture sur le dépôt, donc peut
déclencher le pipeline. C'est le seul chemin d'entrée en dehors du propriétaire.

## L'infrastructure déployée

Six ressources gérées : sous-réseau public, table de routage, association, groupe de sécurité, paire de
clés, instance `t2.micro`.

**Le VPC et sa passerelle Internet sont lus en data source, pas créés.** Le compte de la formation est
partagé et `eu-west-3` est à son quota de 5 VPC, tous appartenant à d'autres étudiants ; toutes les
autres régions sont refusées par un *deny* explicite dans la politique IAM du compte. Supprimer le VPC
d'un camarade n'était pas une option. Conséquence assumée : `terraform destroy` ne peut pas les
supprimer — ce qui est correct, ils ne nous appartiennent pas.

Durcissement de l'instance : `http_tokens = "required"` (IMDSv2 imposé, sans valeur par défaut sûre
dans le provider — Capital One, 2019), limite de sauts à 1, volume racine chiffré, SSH restreint à une
seule `/32`, égress resserré à quatre ports.

L'AMI est **épinglée à un build exact** plutôt que résolue par `most_recent` sur un joker. Deux
raisons, et la seconde n'est pas théorique : un joker résout une image différente au fil du temps et
propose de remplacer l'instance sans qu'on ait rien demandé ; et ce compte tient une **liste blanche
d'AMI par identifiant** — le build le plus récent a été refusé par `RunInstances` avec un *deny*
explicite. Une AMI non épinglée ne démarre tout simplement pas ici.

## Trois défauts trouvés en exécutant, pas en relisant

Aucun n'était visible sur la machine de développement. C'est l'enseignement principal de ce devoir.

**1. Chemin de clé SSH codé en dur.** La sonde de `make configure` pointait sur `~/.ssh/id_ed25519`,
qui existe en CI mais nulle part ailleurs. Le pire type de défaut : la CI serait passée au vert en
laissant croire que tout allait bien. Devenu la variable `SSH_KEY`, qui pilote à la fois la sonde et
`ansible-playbook --private-key`.

**2. Paquet absent d'une version d'Ubuntu.** Le playbook installait `python3-websockets`, présent sur
Ubuntu 26.04 — la machine qui a servi à l'écrire — mais **absent d'Ubuntu 24.04**, celle de l'EC2.
Remplacé par un environnement virtuel avec `websockets==15.0.1` **épinglé** : portable sur les deux, et
reproductible dans six mois. C'est la leçon de l'AMI appliquée aux dépendances Python.

**3. `AWS_PROFILE` exporté en dur.** Le Makefile exportait `AWS_PROFILE=tp2`. Correct sur un poste de
travail ; sur un runner, les identifiants arrivent par variables d'environnement et aucun
`~/.aws/credentials` n'existe, donc le provider cherchait un profil absent :
`failed to get shared config profile, tp2`. L'export est désormais conditionné à l'absence de
`AWS_ACCESS_KEY_ID`. C'est ce défaut qui a fait échouer le premier run réel — sans rien créer, l'échec
précédant `make apply`.

Un quatrième, attrapé avant tout commit : j'avais écrit **de mémoire** les empreintes de commit de deux
actions GitHub. Elles étaient fausses. Résolues par l'API avant publication.

## Coût et destruction

L'instance facture environ **0,45 USD par jour** : `t2.micro` à la demande, adresse IPv4 publique
(facturée depuis février 2024) et volume `gp3`. Le palier gratuit est **par compte, pas par étudiant** —
avec plusieurs instances actives dans ce compte partagé, les 750 h mensuelles partent en une semaine.

Le pipeline accepte une entrée `destroy_after` qui détruit l'instance en fin d'exécution. En local :

```bash
make destroy && make leftovers
```

`make leftovers` filtre sur l'étiquette `Project` : il ne montre que ses propres ressources et ne peut
donc **jamais** désigner celle d'un camarade. Dans un compte partagé, une capture de la page de
facturation ne prouverait rien d'individuel — elle agrège la dépense de toute la promotion. C'est
l'inventaire filtré par étiquette qui fait preuve, ce qui donne à l'étiquetage systématique une
justification comptable en plus de l'inventaire.

Vérifié après le run : aucune instance, aucun volume, aucune IP élastique, aucun sous-réseau portant
mon étiquette. État Terraform à zéro ressource gérée.

## Limites

- **L'OIDC est hors de portée** faute de permissions IAM : des clés longue durée subsistent en secrets.
- **L'environnement `aws-dev` n'a pas de relecteur obligatoire**, pour que la démonstration s'enchaîne.
  L'ajouter met une approbation humaine devant chaque `apply`, y compris ceux du formateur.
- **`sha_pinning_required` est désactivé** au niveau du dépôt. Mes actions sont épinglées par
  discipline ; activer ce réglage l'imposerait à tout futur workflow.
- **Une seule racine, un seul environnement.** Pas de `staging`, pas de modules réutilisables : le
  périmètre du devoir ne les demandait pas et un module qui expose quarante variables est plus difficile
  à utiliser que la ressource brute.

## À retenir

- La condition de provisionnement doit vivre **dans le Makefile autant que dans la CI**. Une garantie
  qui ne fonctionne que sur GitHub n'est pas une propriété du code.
- `terraform plan` **n'est pas** en lecture seule. C'est ce qui justifie de ne jamais lui donner
  d'identifiants sur du code non relu.
- Une dérogation de sécurité s'écrit **à côté du code qu'elle concerne**, avec sa raison et sa date
  d'expiration. Un fichier d'exclusions séparé devient vite une liste que personne ne relit.
- Un tag est un pointeur mutable ; une empreinte est une identité. Vrai pour les actions GitHub, les
  modules Terraform, les images de conteneur — et les AMI.
- **Le code qui ne tourne que sur la machine qui l'a écrit ne tourne pas.** Trois défauts sur trois
  n'ont été trouvés qu'en exécutant ailleurs.
