# Devoir final — Pipeline CI/CD : validation, provisionnement, configuration

**Module 3 — IaC & Terraform** · Blazefive · 31/07/2026
Dépôt : <https://github.com/Blazefive/tp-iac-regis> · Pipeline : `.github/workflows/pipeline.yml`

## Objectif

Un enchaînement entièrement automatisé : événement déclencheur → validations de sécurité → création
de l'EC2 si tout est vert → génération de l'inventaire → configuration via Ansible, sans intervention
manuelle entre les étapes.

## Déclencheur retenu

**`workflow_dispatch`** pour la chaîne complète, **`pull_request`** pour la seule étape 1.

Le dépôt est public. Un déclencheur automatique exposerait le pipeline à toute pull request, or
`terraform plan` n'est pas une opération en lecture seule : provisioners `local-exec`, data sources
`external` et `http` s'exécutent sur le runner. Le job de validation tourne donc sur chaque pull
request **sans aucun identifiant**, et le job de déploiement est réservé au déclenchement manuel, qui
exige le droit d'écriture sur le dépôt.

## Étape 1 — Validation du code d'infrastructure

Trois cibles `make`, dans l'ordre imposé, chacune échouant sur un code de retour non nul.

```
make fmt      terraform fmt -recursive -check -diff
make tflint   tflint --format compact
make trivy    trivy config --exit-code 1 --severity MEDIUM,HIGH,CRITICAL
```

### Ce que les scans ont trouvé

**`tflint`** — `variable "vpc_cidr" is declared but not used`. Séquelle du passage du VPC en data
source : plus aucun lecteur. Variable supprimée.

**`trivy`** — deux constats :

- **AWS-0104 (CRITICAL)**, égress totalement ouvert. **Corrigé** : au lieu de `protocol = "-1"` sur
  tous les ports, l'instance ne sort plus que sur 443, 80, 53/udp, 53/tcp et 123/udp.
- **AWS-0164 (HIGH)**, le sous-réseau attribue une IP publique. Inhérent : la machine sert une
  application publique.

Ce qui reste est assumé dans le code par des commentaires `#trivy:ignore:` portant la justification et
une **date d'expiration**, au-dessus de la ressource concernée. Une dérogation sans échéance est un
trou permanent que personne ne relit.

## Étape 2 — Provisionnement conditionnel

La condition est posée **deux fois**, volontairement :

```yaml
deploy:
  needs: validate       # le job ne démarre pas si une porte est rouge
```

```make
apply: verify           # make apply rejoue fmt, tflint et trivy avant AWS
verify: fmt tflint trivy
```

Sans le second garde-fou, la règle ne vaudrait que dans la CI : un `make apply` lancé depuis un poste
de travail contournerait la validation.

**Observé dans les deux sens.** Le run `30617905792` échoue à `make init` ; `make apply`,
`make inventory` et `make configure` sont tous **`skipped`** et aucune ressource n'est créée. Le run
`30618245903` passe les trois portes et déroule la suite.

### Ce que la condition ne doit surtout pas couvrir : la destruction

`needs:` fait sauter le **job entier** dès qu'une porte est rouge — étape de destruction comprise. Le
run `30621787033` l'a montré en conditions réelles : `tflint` a échoué sur un `403 rate limit
exceeded` de l'API GitHub — `tflint --init` télécharge son ruleset AWS en anonyme, et le quota de 60
requêtes/heure se compte **par adresse IP**, laquelle est partagée sur un runner hébergé. Une panne
sans le moindre rapport avec l'infrastructure a donc rendu une instance en marche impossible à
supprimer depuis le pipeline. Elle a facturé jusqu'à un `terraform destroy` lancé à la main.

Deux corrections, une par défaut :

- **La cause** : le jeton du workflow est passé aux étapes qui invoquent `tflint`, ce qui bascule sur
  le quota par dépôt. Il ne porte que `contents: read` et n'est monté que sur ces deux étapes.
- **Le défaut de conception** : la destruction ne dépend plus des validations.

```yaml
if: >-
  !cancelled()
  && github.event_name == 'workflow_dispatch'
  && (needs.validate.result == 'success' || inputs.action == 'detruire')
```

`!cancelled()` est indispensable : sans fonction d'état explicite, GitHub ajoute un `success()`
implicite et saute le job malgré tout. L'égalité `needs.validate.result == 'success'` reprend alors
le rôle de garde pour tout ce qui crée, et `make apply` reste par ailleurs sauté en mode `detruire`.
La consigne de l'étape 2 est donc intacte : rien ne peut être provisionné par cette porte.

**Une sortie de secours ne doit jamais dépendre de ce qui peut casser.** Conditionner la création aux
validations est la consigne ; y conditionner la destruction transforme la moindre panne de linter en
facture et pousse à nettoyer à la main dans la console — précisément ce que l'IaC cherche à éviter.

## Étape 3 — Récupération de l'adresse IP et génération de l'inventaire

`make inventory` lit la sortie Terraform et écrit le fichier au format attendu par Ansible :

```make
ip="$(terraform -chdir=envs/dev-aws output -raw instance_public_ip)"
```

```ini
[web]
aws-web-01 ansible_host=<ip>

[web:vars]
ansible_user=ubuntu
```

La sortie `instance_public_ip` a été ajoutée pour cela : `public_url` renvoie une URL, pas une adresse
exploitable. La cible apprend aussi la clé d'hôte avec `ssh-keyscan`, ce qui permet de garder
`host_key_checking = True` — la solution courante, désactiver la vérification, transforme chaque
exécution en homme-du-milieu accepté d'avance. L'inventaire est ignoré par Git : il est réécrit à
chaque exécution depuis l'état réel.

## Étape 4 — Configuration automatique de la machine

`make configure` attend que SSH réponde, puis lance `ansible-playbook` sur l'adresse de l'inventaire
généré. Le playbook installe nginx et un service applicatif, puis vérifie son propre travail.

## Résultat

**Run `30618245903`** — toutes les étapes en `success` :

| Étape du workflow | Conclusion |
|---|---|
| `make fmt`, `make tflint`, `make trivy` | success |
| `make init`, `make apply` | success |
| `make inventory` | success |
| `make configure` | success |
| Révocation de la règle SSH temporaire, destruction | success |

Aucune intervention entre les étapes. Après exécution : aucune instance, aucun volume, aucune IP
élastique portant l'étiquette du projet ; état Terraform à zéro ressource gérée.

## Sécurité du workflow

| Mesure | Raison |
|---|---|
| `pull_request`, jamais `pull_request_target` | la seconde forme exécute le code de la PR **avec** les secrets |
| Job de déploiement en `workflow_dispatch` | exige le droit d'écriture : aucun visiteur ne peut le lancer |
| Actions épinglées par empreinte de commit | un tag est mutable — cf. CVE-2025-30066 sur `tj-actions/changed-files` |
| `permissions: contents: read` | le `GITHUB_TOKEN` ne peut rien écrire |
| Règle SSH temporaire pour la seule IP du runner, révoquée en `if: always()` | les runners ont des adresses dynamiques ; ouvrir 22 au monde annulerait l'exercice |
| Clé publique dérivée de la privée | un seul secret, aucune dérive possible |
| Secrets hors du dépôt | `terraform.tfvars`, `backend.hcl` et l'inventaire sont ignorés ; `gitleaks` ne trouve rien |

**Limite assumée** : l'OIDC est impossible. Il faudrait un rôle IAM avec relation de confiance sur
`token.actions.githubusercontent.com`, or l'utilisateur de ce TP n'a aucune permission IAM. Des clés
d'accès longue durée subsistent donc en secrets GitHub. Le correctif n'est pas technique : demander un
rôle, puis supprimer ces deux secrets.

## Infrastructure déployée

Six ressources gérées : sous-réseau public, table de routage, association, groupe de sécurité, paire
de clés, instance `t2.micro`.

Le VPC et sa passerelle Internet sont **lus en data source**, pas créés : le compte de la formation est
partagé et `eu-west-3` est à son quota de 5 VPC, tous appartenant à d'autres étudiants. Conséquence
assumée : `terraform destroy` ne peut pas les supprimer, ce qui est correct puisqu'ils ne nous
appartiennent pas.

Durcissement : `http_tokens = "required"` (IMDSv2 imposé, sans valeur par défaut sûre dans le
provider), limite de sauts à 1, volume racine chiffré, SSH restreint à une seule `/32`, égress
resserré à quatre ports. L'AMI est épinglée à un build exact — ce compte tient une liste blanche d'AMI
par identifiant, et un joker `most_recent` a été refusé par `RunInstances`.

## Reproduire

```bash
make verify      # étape 1
make init
make apply       # étape 2, refuse de partir si l'étape 1 est rouge
make inventory   # étape 3
make configure   # étape 4
make destroy && make leftovers
```

`make leftovers` filtre sur l'étiquette `Project` : il ne montre que ses propres ressources et ne peut
donc jamais désigner celle d'un camarade.
