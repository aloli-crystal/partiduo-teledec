# SPDX-License-Identifier: AGPL-3.0-or-later

# Composition de développement et de test : le cœur et l'interface (réglages
# de `partiduo-ui-bulma`, déjà appliqués à son chargement), puis les
# applications de l'extension. Une distribution fait de même avec toutes ses
# extensions.
Marten.configure do |config|
  config.installed_apps = config.installed_apps + Teledec::INSTALLED_APPS + Teledec::Ui::INSTALLED_APPS
end
