// hash-password.js -- genere le hash scrypt d'un mot de passe admin.
//
// Usage (sur n'importe quelle machine avec Node, ou dans le conteneur) :
//   node hash-password.js
//   node hash-password.js "MonMotDePasse"
//
// Copie la valeur "scrypt$..." affichee dans la variable d'environnement
// PASSWORD_ADMIN_HASH (docker-compose ou .env). Le mot de passe en clair
// n'apparait alors NULLE PART : ni dans le .env, ni dans l'image, ni dans les
// logs. Le BFF ne stocke que le hash et compare a temps constant.

import crypto from "node:crypto"
import readline from "node:readline"

function hash(password) {
  const salt = crypto.randomBytes(16)
  const derived = crypto.scryptSync(password, salt, 32)
  return `scrypt$${salt.toString("hex")}$${derived.toString("hex")}`
}

const argPwd = process.argv[2]
if (argPwd) {
  console.log(hash(argPwd))
  process.exit(0)
}

// Saisie interactive (masquee autant que possible) si pas d'argument.
const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: true })
rl.question("Mot de passe admin a hasher : ", (pwd) => {
  rl.close()
  if (!pwd) { console.error("Mot de passe vide, abandon."); process.exit(1) }
  console.log("")
  console.log("Ajoute cette ligne a ton .env / docker-compose (environment) :")
  console.log("")
  console.log(`  PASSWORD_ADMIN_HASH=${hash(pwd)}`)
  console.log("")
})
