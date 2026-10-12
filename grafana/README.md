# Grafana : dashboards Comparaison ASE

8 dashboards (synthèse + 1 par module), provisionnés par fichiers et versionnés en JSON.
Une barre de liens « Modules » (par tag `compa_ase`) permet de passer d'un module à l'autre en gardant le run sélectionné (`includeVars`).

| Dossier | Contenu |
|---|---|
| `build_dashboards.py` | Générateur des JSON (`python3 grafana/build_dashboards.py`) |
| `dashboards/` | JSON générés : `compa-home`, `compa-<module>` |
| `provisioning/` | Datasource et fournisseur de dashboards |
| `tests/` | Tests de structure et d'exécution des requêtes SQL |

Ne pas éditer les JSON à la main : modifier le générateur puis le relancer.

## Installation (bastion Ubuntu)

1. Installer Grafana OSS selon la documentation officielle (dépôt apt grafana.com), puis `sudo systemctl enable --now grafana-server`.
2. Définir le mot de passe du rôle `grafana_ro` dans PostgreSQL (voir README racine).
3. Déclarer les variables dans `/etc/default/grafana-server` (fichier en `chmod 600`, non versionné) :

```
COMPA_PG_HOST=pg01
COMPA_PG_PORT=5432
COMPA_PG_DB=compa
COMPA_PG_PASSWORD=<mot_de_passe_grafana_ro>
```

4. Copier les fichiers :

```
sudo cp grafana/provisioning/datasources/compa_ase.yaml /etc/grafana/provisioning/datasources/
sudo cp grafana/provisioning/dashboards/compa_ase.yaml  /etc/grafana/provisioning/dashboards/
sudo mkdir -p /var/lib/grafana/dashboards/compa_ase
sudo cp grafana/dashboards/*.json /var/lib/grafana/dashboards/compa_ase/
sudo chown -R grafana:grafana /var/lib/grafana/dashboards
sudo systemctl restart grafana-server
```

5. Dans Grafana : Connections > Data sources > « Comparaison ASE » > **Save & test**. PostgreSQL doit autoriser `grafana_ro` depuis le bastion (`pg_hba.conf`, `listen_addresses`).

## Utilisation

Ouvrir « 0 - Synthèse », choisir un run en haut, puis naviguer avec la barre « Modules ». Le tableau « Écarts par module » de la synthèse ouvre directement le module cliqué.

## Tests

```
python3 grafana/tests/test_dashboards.py                      # structure
COMPA_TEST_PG=1 COMPA_TEST_DB=compa python3 grafana/tests/test_dashboards.py   # + exécution des requêtes (PGHOST/PGUSER...)
```

Les JSON n'ont pas été validés dans un Grafana réel : vérifier visuellement au premier import.
