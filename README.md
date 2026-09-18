# IT Control Room

Application web de gestion et de suivi d'un parc informatique, avec authentification Supabase et données persistantes.

## Démarrage

L'application est une SPA HTML/CSS/JavaScript. Depuis ce dossier, lancer un serveur statique, par exemple :

```powershell
python -m http.server 4173
```

Puis ouvrir `http://localhost:4173`.

## Fonctionnalités

- 63 postes préchargés : Administration (3) et 6 salles (10 chacune)
- Dashboard, salles, fiches PC, problèmes, interventions et historique
- Authentification par Supabase Auth et rôles stockés dans `profiles`
- Données persistantes dans Supabase avec RLS pour les administrateurs et techniciens
- Catégories réseau limitées à la liste métier demandée

## Backend Supabase

Le schéma complet, les politiques RLS, l'historique et les 63 postes sont définis dans `supabase/migrations/20260918000000_initial_schema.sql`.
Le client utilise `supabase-config.js`, qui doit contenir l'URL du projet et sa clé publishable.
