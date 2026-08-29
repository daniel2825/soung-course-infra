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
