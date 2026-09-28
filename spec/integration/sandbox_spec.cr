# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Suite d'intégration contre le bac à sable de TELEDEC : optionnelle, elle
# attend la documentation de l'API partenaire (`~/.config/partiduo/teledec/`)
# et des identifiants de test (`~/.config/partiduo/teledec-sandbox.env`).
# Le partenariat a été demandé le 27 septembre 2026 ; tant que l'un manque,
# l'adaptateur réel n'est pas écrit (BLOCAGES B-TDC-001) et la suite est en
# attente. Les secrets ne sont jamais affichés ni journalisés.
private def sandbox_ready? : Bool
  home = ENV["HOME"]? || return false
  docs = File.join(home, ".config/partiduo/teledec")
  env = File.join(home, ".config/partiduo/teledec-sandbox.env")
  Dir.exists?(docs) && !Dir.children(docs).empty? && File.exists?(env) &&
    File.read(env).lines.any? { |line| line.includes?('=') && !line.split('=', 2)[1].strip.empty? }
rescue File::Error
  false
end

describe "Bac à sable TELEDEC (intégration, optionnelle)" do
  if sandbox_ready?
    pending "documentation et identifiants présents : écrire l'adaptateur réel (BLOCAGES B-TDC-001)"
  else
    pending "en attente de la documentation de l'API partenaire et des identifiants de test (BLOCAGES B-TDC-001)"
  end
end
