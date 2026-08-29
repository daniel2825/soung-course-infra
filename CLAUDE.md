# Contexto: conversación original (2026-08-28)

> Registro de la sesión en la que se generó este documento. Se conserva como
> material de referencia y trazabilidad de decisiones. **La síntesis accionable
> está más abajo, en "Sistema `song-course`"** — si buscas cómo trabajar en el
> proyecto, salta a esa sección.

---

## 1. Inventario de la carpeta

**Usuario:** «lista todos los proyectos que estan en esta carpeta»

**Claude:** Listado de las 37 carpetas en `/home/daniel/Documents/Proyectos`,
agrupadas por stack (Java/Spring, JS/React, Scala, Infra/DevOps, Neo4j, otros).
Las 4 relevantes para este sistema: `soung-course-js`, `soung_course_infra`,
`song-course-java`, `song-course-scala-kakfa`. El resto son proyectos antiguos
e independientes (bpop, HistoriaClinica, daguitoys, spotify, mallplaza, etc.).

---

## 2. Descripción del sistema y petición de análisis

**Usuario:**

> estoy construyendo una aplicacion movil de cursos de canto en el cual una
> persona se registra en la aplicacion luego hace su login para acceder a los
> cursos de canto e inscribirse a cada uno de ellos, esto llega a una base de
> datos en neo4j, pero también dinamicamente estoy cargando contenido de los
> cursos a traves de terraform. Analiza los proyectos y entiende la
> arquitectura estan distribuidos por roles, como se envia la informacion y los
> conceptos importantes que se utilizan en los proyectos. Analiza
> @soung-course-js/ @soung_course_infra/ @song-course-java/
> @song-course-scala-kakfa/

**Claude:** análisis completo, reproducido a continuación.

### 2.1 Los cuatro roles

| Proyecto | Rol | Stack | Puerto / destino |
|---|---|---|---|
| `soung-course-js` | Cliente móvil + definición del backend serverless | Expo 54 / RN 0.81 / React 19 + Amplify Gen 2 (CDK) | Android/iOS |
| `soung_course_infra` | Pipeline de contenido declarativo | Terraform + AWS provider 6.39 | S3 + DynamoDB de Amplify |
| `song-course-java` | Backend de dominio: personas, inscripciones, progreso | Spring Boot 3.5.4 / Java 21 / Spring GraphQL / Spring Data Neo4j | `:9081/graphql` |
| `song-course-scala-kakfa` | Consumidor de eventos hacia el grafo | Scala 3.8.3 / Cats Effect / fs2-kafka / driver Neo4j | Kafka `:9092` → Neo4j |

La decisión estructural central es una **partición por naturaleza del dato**:

- **Contenido** (títulos, módulos, banners, videos) → inmutable, pesado, se
  publica → **DynamoDB + S3**, escrito por Terraform.
- **Relaciones** (quién está inscrito en qué, cuánto lleva) → altamente
  conectado, se consulta por caminos → **Neo4j**, escrito por Spring.

El **email de Cognito es la única llave de correlación** entre ambos mundos, y
el `id` del ítem de DynamoDB es el `idCourse` del grafo. Todo el sistema se
sostiene sobre esos dos identificadores.

### 2.2 Flujo de información, extremo a extremo

#### Registro y login (dos registros distintos)

```
Usuario → <Authenticator> (Amplify UI, i18n español)
        → Cognito User Pool us-west-1_IUiVjc6v0   [credencial]
        → user.signInDetails.loginId = email
```

`app/index.jsx:110` monta `ApolloProvider > ThemeProvider > Authenticator.Provider
> Authenticator > MainNavigator`. Nada del árbol se renderiza sin sesión Cognito.

Luego `app/Home/init.jsx:47` hace el **segundo registro**, el de dominio:

```
getPerson(email) → Spring :9081 → MATCH (p:Person {email}) RETURN p LIMIT 1
   null  → pantalla "Personal" → addPerson(name,email,lastName,birthDay)
                               → MERGE (p:Person {...})
   ≠null → "(tabs)"
```

Cognito guarda la **credencial**; Neo4j guarda la **persona**. Son dos ciclos de
vida separados unidos por email.

#### Publicación de contenido (Terraform)

`soung_course_infra/content/main.tf` no crea infraestructura — se **adhiere** a
la que Amplify ya desplegó:

```hcl
data "aws_s3_bucket"      "amplify_assets" { bucket = "amplify-d1q7yw091jwae4-..." }
data "aws_dynamodb_table" "amplify_table"  { name   = "SongCourseContent-uvelwqaz...-NONE" }
```

Y sobre eso hace dos cosas:

1. **`null_resource.upload_to_s3`** — trigger = `md5(join(...filemd5 de todo
   upload/**))`. Si cambia un byte de cualquier video, se dispara
   `aws s3 sync upload/ s3://bucket/ --delete`.
2. **`aws_dynamodb_table_item.course_items`** — `for_each` sobre `courses_map`
   (derivado de `jsondecode(cursos.json)`), escribiendo el ítem con `modules`
   como lista de mapas DynamoDB (`{L = [{M = {...}}]}`), con
   `depends_on = [null_resource.upload_to_s3]` para que **el video exista en S3
   antes de aparecer en la base**.

El JSON es la fuente de verdad del catálogo.
`banner_image: "images/resonancia/bannerjair.jpg"` es simultáneamente la clave
S3 y el valor en DynamoDB — por eso la app puede pasarlo directo a
`getUrl({path})`.

#### Consumo del catálogo

```
CourseList.jsx → client.models.SongCourseContent.list()   [AppSync, userPool auth]
               → por cada banner_image: getUrl({path})    [URL prefirmada S3]
               → <Image source={{uri: url}}>
```

#### Inscripción — el punto donde convergen los dos backends

`CourseList.jsx:68` toma el ítem de **DynamoDB** y lo manda a **Spring**:

```graphql
subscribePersonToCourse(
  person:  { email }
  course:  { idCourse: <id de DynamoDB>, title }
  modules: [{ module_number, module_title }]   # proyección: se descartan video, color, content
)
```

Spring ejecuta tres Cypher (`CoursesServices.java:32`):

```cypher
MERGE (c:Course {idCourse, title})
MERGE (p)-[:IS_SUBSCRIBED_TO {total_progress:'0'}]->(c)
-- por cada módulo:
MERGE (m:Module {module_title, module_number})
MERGE (c)-[:HAS_MODULE_OF]->(m)
MERGE (p)-[:HAS_PROGRESS_MODULE {completed:'0'}]->(m)
```

El grafo resultante:

```
(Person)-[:IS_SUBSCRIBED_TO {total_progress}]->(Course)-[:HAS_MODULE_OF]->(Module)
   └──────────────[:HAS_PROGRESS_MODULE {completed}]────────────────────┘
```

#### Progreso

**El progreso no es un nodo, es una propiedad de arista.** `total_progress` vive
en `IS_SUBSCRIBED_TO`. Es la decisión de modelado más importante del proyecto:
el progreso *es* la relación persona-curso, así que modelarlo como propiedad de
la arista evita un nodo `Progress` por par (persona, curso).

```cypher
-- lectura  (IProgressRepository:26)
MATCH (p:Person {email})-[r:IS_SUBSCRIBED_TO]->(c:Course {idCourse})
RETURN id(r) AS idProgress, r.total_progress AS total_progress
-- escritura
SET r.total_progress = $completed
```

El tipo GraphQL `Progress` es una **proyección de arista**, no un `@Node` real
(aunque `Progress.java` esté anotado como tal — el OGM no se usa).

#### Composición de campos con `GraphQLContext`

`TrackingList.jsx` pide un árbol anidado:

```graphql
getPerson(email) { id, course { idCourse, title, progress { total_progress } } }
```

Resuelto en tres saltos:

- `PersonsController.getPerson` → `context.put("currentPersonEmail", email)`
- `@SchemaMapping(field="course")` → `getCoursesSubscribePerson(person.getEmail())`
- `@SchemaMapping(typeName="Course", field="progress")` → **recupera el email del
  `GraphQLContext`**, porque `Course` por sí solo no sabe de quién es el progreso.

Este es el truco más interesante del backend Java: `Progress` depende de un par
(persona, curso), pero GraphQL sólo entrega el padre inmediato al resolver. El
`GraphQLContext` transporta la mitad faltante a lo largo de la request.

#### La ruta Kafka (construida, hoy inactiva)

```
Spring PersonsServices  → kafkaTemplate.send("test-topic", personaJson)       ← COMENTADO
Spring CoursesServices  → kafkaTemplate.send("subscribe-course", eventJson)   ← COMENTADO
                              ↓
Scala Main (IOApp.Simple): Neo4jConnection.resource.use { driver =>
   Stream.emits(List(personConsumer.stream, courseConsumer.stream))
         .parJoinUnbounded.compile.drain }
                              ↓
   fs2-kafka → circe decode[Person] / decode[CourseSubscriptionEvent] → Cypher MERGE
```

Los consumidores existen, compilan y están suscritos; **nadie produce**. El
pipeline está listo pero desconectado.

### 2.3 Conceptos técnicos clave

**Polyglot persistence con frontera por identificador.** DynamoDB no conoce
personas; Neo4j no conoce videos. El `idCourse` es el contrato.

**Dos GraphQL en el mismo cliente.** AppSync (generado por el DSL `a.schema()`
de Amplify, auth Cognito) y Spring GraphQL (schema-first en `schema.graphqls`,
sin auth). Conviven porque usan clientes distintos: `generateClient()` vs
`ApolloClient`. Es inusual y funciona, pero significa que **la app tiene dos
modelos de autorización, y sólo uno existe**.

**Infra-as-data.** Terraform como CMS: el contenido vive en git como JSON +
binarios, y `terraform apply` es el "publicar".

**Cats Effect.** `Resource.make/close` garantiza cierre del driver Neo4j;
`parJoinUnbounded` corre N consumidores concurrentes en una fibra por stream.
Cero hilos manuales.

**Pitch detection en vivo** (`@techoptio/react-native-live-pitch-detection`,
`content.jsx:114`) — buffer 4096, minVolume −50 dB, 100 ms. Es el diferenciador
de dominio: el JSON de cursos ya lleva `frecuency_example` con
`{frequency, note, noteLetter, noteOctave, second}`, o sea que el diseño apunta a
**comparar la frecuencia cantada contra una referencia por segundo de video**.
Ese campo aún no se sube a DynamoDB.

**Onboarding animado** con `Animated.FlatList` + `useAnimatedScrollHandler` +
`interpolate` sobre `scrollX` — cada módulo es un slide con su `color` (que viene
de `cursos.json` → Terraform → DynamoDB).

### 2.4 Problemas encontrados, por severidad

#### 🔴 El backend Java no valida identidad

`getPerson(email)`, `getCourseSubscribePerson(email)`,
`modifyProgressNode(email, ...)` toman el email como **argumento GraphQL**, nunca
como identidad verificada. Spring no valida el JWT de Cognito, y
`spring.graphql.cors.allowed-origins=*`. Cualquiera con acceso al puerto 9081 lee
y modifica los datos de cualquier usuario. Amplify protege el catálogo; el
dominio queda abierto.

#### 🔴 Los videos no tienen permiso de lectura en S3

`amplify/storage/resource.ts` sólo concede `'images/*'`, y se confirmó en el
estado desplegado (`amplify_outputs.json` → `paths: { "images/*": {...} }`). Pero
`content.jsx:139` llama `getUrl({ path: item.banner_video })` con paths
`videos/...`. Falta:

```ts
'videos/*': [allow.authenticated.to(['read'])],
```

#### 🟠 `aws s3 sync --delete` sobre el bucket de Amplify

`main.tf:30` borra del bucket todo lo que no esté en `upload/`. Como es el
**mismo bucket** que Amplify usa para las escrituras autenticadas de la app
(`allow.authenticated.to(['write'])`), cualquier archivo subido desde la app
desaparece en el siguiente `apply`. Convendría separar prefijos: sincronizar sólo
`s3://bucket/images/ videos/` o quitar `--delete`.

#### 🟠 Drift permanente en Terraform

```hcl
"createdAt" = { S = formatdate(..., timestamp()) }
"updatedAt" = { S = formatdate(..., timestamp()) }
```

`timestamp()` se re-evalúa en cada `plan`, así que **los dos cursos siempre
aparecen como modificados**. Irónicamente `cursos.json` ya trae
`createdAt`/`updatedAt` y no se usan. Usar `each.value.createdAt`, o
`lifecycle { ignore_changes = [item] }`.

#### 🟠 Bug latente en `getFileUrl` (dos archivos)

`CourseList.jsx:104` y `ProgressCourseList.jsx:87`:

```js
courses_list.map(item => { setBannerPaths(bannerPaths.push(item.banner_image)) });
```

`Array.push` devuelve **la nueva longitud**, así que se guarda un número en el
state, y además se muta el array del state directamente. Sobrevive sólo porque el
`.map` posterior usa la referencia del closure y `getFileUrl` se llama una vez. Si
el componente vuelve a montarse con state persistido o se llama dos veces,
`bannerPaths.map is not a function`. El array es local, no hace falta state:

```js
const bannerPaths = courses_list.map(item => item.banner_image);
```

#### 🟠 Doble escritura si se reactiva Kafka

Con el código descomentado, Spring escribiría a Neo4j **y** publicaría el evento,
y el consumer Scala volvería a escribir. Es idempotente por los `MERGE`, pero el
consumer Scala sólo hace `Course` + `IS_SUBSCRIBED_TO` — **no crea módulos ni
`total_progress`**. Quedarían inscripciones sin la propiedad de progreso que
`TrackingList` espera leer, y `item.progress.total_progress` reventaría. Hay que
decidir una sola ruta de escritura antes de encender el productor.

#### 🟡 N+1 hacia Neo4j

`@SchemaMapping(field="course")` → 1 query por persona; `@SchemaMapping(field="progress")`
→ 1 query **por curso**. Un usuario con 20 cursos = 21 round trips. `@BatchMapping`
resolvería el segundo caso en una sola consulta.

#### 🟡 `GraphQLContext` acopla las queries

`progress` sólo funciona si `getPerson` corrió antes en la misma request.
`getCourseSubscribePerson(email) { progress }` — que el schema permite —
devolvería `context.get("currentPersonEmail") == null`. Es una dependencia
implícita entre resolvers que el schema no expresa.

#### 🟡 `ProgressContentCourse.jsx` está roto y huérfano

Usa `useState`, `useEffect`, `useRef`, `useCallback` y `getUrl` **sin
importarlos**, y declara hooks después de un `return` condicional (viola las
reglas de hooks). No explota sólo porque `Progress_content_navigator.jsx:5`
importa `ProgressContentCourse from "../Content/content"` — el archivo homónimo
nunca se carga. Además `TrackingList.jsx:84` navega a `'ProgressContentCourse'`,
ruta **no registrada** en `tracking_navigator.jsx` → el tap no hace nada.

#### 🟡 Propagación de `email` por `route.params`

`UserDetailContext` está creado pero comentado en `_layout.jsx:12`, así que el
email se pasa a mano en cada nivel: tabs → `initialParams` → navigator → screen.
Cinco archivos hacen `const { email } = route.params` sin guarda; cualquier
montaje sin params lanza `Cannot destructure`.

#### 🟡 Configuración hardcodeada

- `apolloClient.js` → `http://172.18.0.1:9081/graphql` (IP del bridge de Docker),
  con las otras dos alternativas comentadas encima. Necesita `expo-constants` / `.env`.
- Password Neo4j `12345678` en `application.properties` y `Neo4jConnection.scala:18`.
- Nombres de bucket y tabla copiados a mano en `main.tf:4-6`, cuando Terraform
  puede leerlos: `jsondecode(file(".../amplify_outputs.json"))`.
- `DataBaseConfig.java:36` → `"bllolt://localhost:7687"` (typo, tres `l`). Está en
  un campo estático no usado, así que no rompe nada hoy.

#### 🟢 Código muerto

`PersonsComponent` / `CoursesComponent` (vacíos), `KafkaSettings.scala` /
`KafkaEnrollmentConsumer.scala` / `AplicationConfig.scala` (vacíos),
`OpenAiEmbeddingModel` (stub que devuelve `null`, y Spring AI vector-store está en
el `build.gradle` sin usarse), `CountryCity` + `first-graph.cyp` (del tutorial de
Neo4j), `ICoursesRepository.subscribeCourse(email, ...)` recibe `email` y el
Cypher no lo usa, `PersonQueries.findByEmail/update/delete` apuntan a `:Persona`
(label inexistente — el resto usa `:Person`), `doctoralia.json` usa el esquema
viejo `videos` y `main.tf` no lo carga.

---

## 3. Creación de este documento

**Usuario:** «gracias, excelente analisis. Ahora con esta informacion que tienes
en contexto crea el archivo claude.md para que se puede utilizar como memoria
dentro de este proyecto.»

**Claude:** se creó `CLAUDE.md` en `/home/daniel/Documents/Proyectos/` (raíz común
de los 4 repos, ya que cada uno es un git independiente y no hay raíz dentro del
sistema). Se señalaron dos pendientes: la ubicación afectaba a los otros 33
proyectos de la carpeta, y el archivo no quedaba versionado en ningún repo.

---

## 4. Distribución a los 4 repositorios

**Usuario:** «crea ese archivo por cada repositorio y subelo a cada uno de los
proyectos con el mismo contenido posteriormente lo mejorare.»

**Claude:** se preguntó cómo subirlo dado que los 4 repos estaban en su rama por
defecto. **Decisión del usuario: push directo a la rama por defecto.**

Resultado — mismo contenido (md5 `dbcaf1d9…`, 197 líneas) en los 4, un solo
archivo por commit, sin tocar los cambios sin commitear preexistentes:

| Repo | Rama | Commit |
|---|---|---|
| `soung-course-js` | master | `4e110b2` |
| `soung_course_infra` | main | `8e1b19e` |
| `song-course-java` | master | `37f3670` |
| `song-course-scala-kakfa` | main | `c96e4aa` |

Pendientes señalados: borrar el `CLAUDE.md` de la carpeta padre (ahora duplica
contenido al cargarse junto con el del repo), y añadir `terraform.tfstate` +
`.terraform/` al `.gitignore` de `soung_course_infra`.

---

## 5. Registro de la conversación

**Usuario:** «ahora guarda nuestra conversacion al principio en ese mismo archivo
claude.md en cada uno de los proyectos.»

**Claude:** esta sección, prependida al `CLAUDE.md` de los 4 repos.

---
---

# CLAUDE.md — Sistema `song-course` (app móvil de cursos de canto)

> Este archivo describe **un sistema distribuido en 4 repos hermanos** dentro de
> `/home/daniel/Documents/Proyectos`. Los demás directorios de esta carpeta son
> proyectos antiguos e independientes; no tienen relación con esto.

## Los 4 componentes

| Repo | Rol | Stack | Endpoint |
|---|---|---|---|
| `soung-course-js` | App móvil + definición del backend serverless | Expo 54 / RN 0.81 / React 19 / Amplify Gen 2 | Android/iOS |
| `soung_course_infra` | Pipeline de publicación de contenido | Terraform + AWS provider 6.39, región `us-west-1` | S3 + DynamoDB |
| `song-course-java` | Dominio: personas, inscripciones, progreso | Spring Boot 3.5.4 / Java 21 / Spring GraphQL / Spring Data Neo4j | `:9081/graphql` |
| `song-course-scala-kakfa` | Consumidor de eventos hacia el grafo (**inactivo**) | Scala 3.8.3 / Cats Effect / fs2-kafka / driver Neo4j | Kafka `:9092` |

## Principio arquitectónico central

Partición por **naturaleza del dato**:

- **Contenido** (títulos, módulos, banners, videos) → inmutable y pesado → **DynamoDB + S3**, escrito por Terraform.
- **Relaciones** (quién está inscrito en qué, cuánto lleva) → altamente conectado → **Neo4j**, escrito por Spring.

Dos identificadores sostienen todo el sistema:

1. **El email de Cognito** correlaciona AWS ↔ Neo4j.
2. **El `id` del ítem de DynamoDB == el `idCourse` del grafo** (Terraform escribe `id = each.value.id_course`).

Si tocas cualquiera de los dos, se rompe la unión entre las dos mitades.

## Comandos

```bash
# App móvil
cd soung-course-js && npx expo start          # dev server
npx expo run:android                          # build nativo (necesario: pitch detection es módulo nativo)
npx ampx sandbox                              # backend Amplify efímero

# Backend Java  (requiere Neo4j en bolt://localhost:7687, db song-track-db)
cd song-course-java && ./gradlew bootRun       # GraphiQL en http://localhost:9081/song-course

# Consumidor Scala
cd song-course-scala-kakfa && docker compose up -d && sbt run

# Contenido
cd soung_course_infra/content && terraform plan && terraform apply
```

## Flujos

### Registro / login — son DOS registros

Cognito guarda la **credencial**; Neo4j guarda la **persona**. Ciclos de vida separados.

```
<Authenticator> (Amplify UI, i18n 'es') → user.signInDetails.loginId = email
  → app/Home/init.jsx: getPerson(email) contra Spring
      null  → pantalla "Personal" → mutation addPerson → MERGE (p:Person)
      ≠null → "(tabs)"
```

### Publicación de contenido (Terraform)

`soung_course_infra/content/main.tf` **no crea infraestructura**: se adhiere con `data` sources
al bucket y la tabla que Amplify ya desplegó (nombres hardcodeados en `locals`).

1. `null_resource.upload_to_s3` — trigger = md5 de todos los `filemd5` de `upload/**` → `aws s3 sync ... --delete`
2. `aws_dynamodb_table_item.course_items` — `for_each` sobre `jsondecode(cursos.json)`, con
   `depends_on` al sync para que **el video exista en S3 antes de aparecer en la base**.

`cursos.json` es la fuente de verdad del catálogo. `banner_image` / `banner_video` son
simultáneamente clave S3 y valor en DynamoDB — por eso la app los pasa directo a `getUrl({path})`.

### Inscripción — donde convergen los dos backends

`CourseList.jsx` toma el ítem de **DynamoDB** y lo envía a **Spring**:

```graphql
subscribePersonToCourse(
  person:  { email }
  course:  { idCourse: <id de DynamoDB>, title }
  modules: [{ module_number, module_title }]   # proyección: se descartan banner_video, color, content
)
```

Grafo resultante:

```
(Person)-[:IS_SUBSCRIBED_TO {total_progress}]->(Course)-[:HAS_MODULE_OF]->(Module)
   └──────────────[:HAS_PROGRESS_MODULE {completed}]────────────────────┘
```

### Progreso

**El progreso NO es un nodo: es una propiedad de arista.** `total_progress` vive en
`IS_SUBSCRIBED_TO`. El progreso *es* la relación persona-curso, así que va en la arista.
El tipo GraphQL `Progress` es una proyección (`RETURN id(r) AS idProgress, r.total_progress`),
no una entidad. `Progress.java` está anotado `@Node` pero el OGM **no se usa** — todo es
Cypher a mano vía `@Query`.

### `GraphQLContext` transporta el email entre resolvers

`Course.progress` depende del par (persona, curso), pero GraphQL sólo entrega el padre inmediato.
Solución en `PersonsController.getPerson`: `context.put("currentPersonEmail", email)`, recuperado
en `@SchemaMapping(typeName="Course", field="progress")`.

⚠️ Esto crea una **dependencia implícita**: `progress` sólo funciona si `getPerson` corrió en la
misma request. `getCourseSubscribePerson(email) { progress }` — que el schema permite — daría null.

### Kafka: construido, hoy desconectado

Los `kafkaTemplate.send(...)` en `PersonsServices` y `CoursesServices` están **comentados**.
Los consumidores Scala (`test-topic`, `subscribe-course`) compilan y están suscritos, pero
nadie produce.

**Antes de reactivarlo:** habría doble escritura (Spring escribe a Neo4j *y* publica; Scala
vuelve a escribir). Es idempotente por los `MERGE`, pero el consumer Scala **sólo crea `Course` +
`IS_SUBSCRIBED_TO`, sin módulos ni `total_progress`** → `TrackingList` leería
`item.progress.total_progress` sobre un null. Decide una sola ruta de escritura primero.

## Convenciones del código

- **Dos clientes GraphQL en la misma app**: `generateClient()` (AppSync, auth Cognito) para el
  catálogo, y `ApolloClient` (Spring, sin auth) para el dominio. No los mezcles.
- **Navegación híbrida**: expo-router file-based en `app/` + `(tabs)`, con stacks de
  react-navigation anidados *dentro* de cada tab (`content_navigator`, `tracking_navigator`,
  `Progress_content_navigator`). Hay tres `ApolloProvider` anidados.
- **El email se propaga a mano** por `route.params` en cada nivel. `UserDetailContext` existe
  pero está comentado en `_layout.jsx`.
- Java: `Controller → Services → Repository (Neo4jRepository con @Query Cypher)`. Los
  `component/` están vacíos.
- Scala: `Consumer → Service → Repository`, queries como `String` en `querys/`, driver Java
  envuelto en `Resource` de Cats Effect, `parJoinUnbounded` para correr N consumidores.
- El dominio de canto está en `@techoptio/react-native-live-pitch-detection` (`content.jsx`):
  buffer 4096, minVolume −50 dB, 100 ms. `cursos.json` ya trae `frecuency_example`
  (`{frequency, note, noteLetter, noteOctave, second}`) para comparar tono cantado vs. referencia,
  **pero ese campo aún no se sube a DynamoDB** (`main.tf` no lo mapea).

## Problemas conocidos (no los reintroduzcas; arréglalos si tocas la zona)

### Críticos
- **Spring no valida identidad.** `getPerson(email)`, `modifyProgressNode(email,...)` toman el
  email como argumento GraphQL, nunca como JWT verificado. Más `cors.allowed-origins=*`.
  Cualquiera en la red lee/modifica datos de cualquier usuario.
- **Los videos no tienen permiso de lectura en S3.** `amplify/storage/resource.ts` sólo concede
  `'images/*'` (confirmado en `amplify_outputs.json`), pero `content.jsx` hace
  `getUrl({path: item.banner_video})` con paths `videos/...`. Falta `'videos/*': [allow.authenticated.to(['read'])]`.

### Serios
- **`aws s3 sync --delete` sobre el bucket de Amplify** borra todo lo que no esté en `upload/`,
  incluidas las escrituras autenticadas de la app al mismo bucket.
- **Drift permanente en Terraform**: `createdAt`/`updatedAt` usan `timestamp()`, que se re-evalúa
  en cada `plan`. `cursos.json` ya trae esos campos y no se usan.
- **Bug latente en `getFileUrl`** (`CourseList.jsx` y `ProgressCourseList.jsx`):
  `setBannerPaths(bannerPaths.push(x))` guarda un **número** en el state (push devuelve la
  longitud) y muta el array. Sobrevive sólo porque se llama una vez. Usa un array local.
- **N+1 hacia Neo4j**: `@SchemaMapping` de `course` (1 query) y de `progress` (1 query **por
  curso**). Usa `@BatchMapping`.

### Menores
- `ProgressContentCourse.jsx` está **roto y huérfano**: usa `useState`/`useEffect`/`useRef`/
  `useCallback`/`getUrl` sin importarlos y declara hooks tras un `return` condicional. No explota
  porque `Progress_content_navigator` importa desde `../Content/content`. Además `TrackingList`
  navega a `'ProgressContentCourse'`, ruta no registrada en `tracking_navigator` → el tap no hace nada.
- Config hardcodeada: `apolloClient.js` → `http://172.18.0.1:9081/graphql` (IP del bridge Docker);
  password Neo4j `12345678` en `application.properties` y `Neo4jConnection.scala`; nombres de
  bucket/tabla copiados a mano en `main.tf` (Terraform podría leer `amplify_outputs.json`).
- `DataBaseConfig.URL` tiene el typo `"bllolt://"` (campo estático sin uso).
- `PersonQueries.findByEmail/update/delete` usan el label `:Persona`, que **no existe** — el resto
  del sistema usa `:Person`.
- `ICoursesRepository.subscribeCourse` recibe `email` y el Cypher no lo usa.
- `doctoralia.json` usa el esquema viejo (`videos` en vez de `modules`) y `main.tf` no lo carga.
- Código muerto: `PersonsComponent`, `CoursesComponent`, `KafkaSettings.scala`,
  `KafkaEnrollmentConsumer.scala`, `AplicationConfig.scala`, `CountryCity`, `first-graph.cyp`,
  `OpenAiEmbeddingModel` (stub que devuelve null; Spring AI vector-store está en `build.gradle` sin usarse).

## Diagrama

```
┌───────────────── soung-course-js (Expo) ─────────────────┐
│  <Authenticator> ──── Cognito ──── credencial            │
│    generateClient()          ApolloClient                │
└─────────┼─────────────────────────┼──────────────────────┘
          │ AppSync (userPool)      │ HTTP :9081 (sin auth ⚠)
          ▼                         ▼
   ┌─────────────┐          ┌──────────────────┐
   │  DynamoDB   │          │  Spring GraphQL  │
   │ + S3 (media)│          │  Java 21         │
   └──────▲──────┘          └────────┬─────────┘
          │ write                    │ Cypher
   ┌──────┴──────────┐               ▼
   │   TERRAFORM     │      ┌──────────────────┐      ┌──────────────┐
   │  cursos.json    │      │     Neo4j        │◄─────│ Scala/fs2    │
   │  upload/**      │      │  song-track-db   │      │ (sin eventos)│
   └─────────────────┘      └──────────────────┘      └──────▲───────┘
                                                             │
                                                    Kafka ───┘ (productor comentado)
```
