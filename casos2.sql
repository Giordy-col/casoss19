-- =====================================================================
-- S19. Taller: detectar y corregir esquemas mal diseñados
-- casos.sql - Parte A: los cuatro casos
--
-- Integrantes:
--   Juan Esteban Mina       - 2518466
--   Cristian Camilo Criollo - 2517199
--   Giordy Santiago Arcila  - 2242797
--   Jairo A. Tegüé Gómez    - 2416227
--
-- Para correrlo (desde entorno-docker/, base tienda):
--   primero cargar los datos del profe:

--     docker compose exec postgres psql -U curso -d tienda -f /tmp/S19-esquemas.sql
--   y despues este archivo:

--     docker compose exec postgres psql -U curso -d tienda -a -f /tmp/casos.sql
-- =====================================================================


-- #####################################################################
-- CASO 1: GIMNASIO
-- #####################################################################
SET search_path TO gimnasio;

-- (a) Diagnostico
-- Queja: en Yoga el sistema dice 2 socios pero son 3, y en Spinning dice 3
-- pero son 2.
--
-- Dependencias:
--   id_socio -> nombre, plan
--   plan -> valor_plan
--   socio y clase es muchos a muchos. Spinning y Spinning avanzado son
--   clases diferentes.
--
-- El problema principal es que la columna clases tiene varias clases
-- separadas por ';', o sea no esta en 1FN. Para contar toca usar LIKE y ahi
-- falla: '%Yoga%' no encuentra 'yoga' en minuscula (Maria), por eso da 2, y
-- '%Spinning%' tambien coge 'Spinning avanzado' (Pedro), por eso da 3.
-- Ademas hay datos mal escritos: 'yoga', 'Yoga ' con espacio, 'Pilates;yoga'.
--
-- Tambien hay una dependencia transitiva (no esta en 3FN):
-- id_socio -> plan -> valor_plan. El valor del plan se repite en cada socio,
-- si cambia el precio del Mensual toca cambiar 3 filas, y no se puede crear
-- un plan si no hay un socio con ese plan.

-- (b) Evidencia

-- conteo de Yoga con LIKE: da 2 y deberian ser 3
SELECT count(*) AS socios_yoga_segun_sistema
FROM socio WHERE clases LIKE '%Yoga%';

-- conteo de Spinning con LIKE: da 3 y deberian ser 2
SELECT count(*) AS socios_spinning_segun_sistema
FROM socio WHERE clases LIKE '%Spinning%';

-- que filas coge cada LIKE (Maria sale false en yoga, Pedro sale true en spinning)
SELECT id_socio, nombre, clases,
       clases LIKE '%Yoga%'     AS like_yoga,
       clases LIKE '%Spinning%' AS like_spinning
FROM socio
ORDER BY id_socio;

-- el valor del plan repetido: Mensual 3 veces, Anual 2, Trimestral 1
SELECT plan, valor_plan, count(*) AS veces
FROM socio GROUP BY plan, valor_plan ORDER BY veces DESC;

-- revisar que plan -> valor_plan se cumple (debe dar 0 filas)
SELECT plan FROM socio GROUP BY plan HAVING count(DISTINCT valor_plan) > 1;

-- Limpieza: 'yoga', 'Yoga' y 'Yoga ' son la misma clase, entonces usamos
-- trim e initcap. 'Spinning avanzado' queda 'Spinning Avanzado' y sigue
-- siendo otra clase.

-- (c) Esquema corregido
--   plan (plan PK, valor_plan)
--   socio (id_socio PK, nombre, plan FK)
--   clase (nombre_clase PK)
--   socio_clase (id_socio FK, nombre_clase FK, PK de las dos)

-- (d) Migracion
-- conteos esperados antes de migrar: 3 planes, 6 socios, 5 clases, 9 inscripciones
SELECT (SELECT count(DISTINCT plan) FROM socio) AS planes_esperados,
       (SELECT count(*) FROM socio)             AS socios_esperados,
       (SELECT count(DISTINCT initcap(trim(c)))
          FROM socio s, string_to_table(s.clases, ';') AS c
         WHERE trim(c) <> '')                   AS clases_esperadas,
       (SELECT count(DISTINCT (s.id_socio, initcap(trim(c))))
          FROM socio s, string_to_table(s.clases, ';') AS c
         WHERE trim(c) <> '')                   AS inscripciones_esperadas;

BEGIN;

CREATE TABLE plan (
    plan        varchar(20) PRIMARY KEY,
    valor_plan  integer     NOT NULL CHECK (valor_plan > 0)
);
INSERT INTO plan SELECT DISTINCT plan, valor_plan FROM socio;

CREATE TABLE socio_nuevo (
    id_socio  integer     PRIMARY KEY,
    nombre    varchar(80) NOT NULL,
    plan      varchar(20) NOT NULL REFERENCES plan (plan)
);
INSERT INTO socio_nuevo SELECT id_socio, nombre, plan FROM socio;

-- partir la celda de clases y limpiar
CREATE TABLE clase (
    nombre_clase  varchar(40) PRIMARY KEY
);
INSERT INTO clase
SELECT DISTINCT initcap(trim(c))
FROM socio s, string_to_table(s.clases, ';') AS c
WHERE trim(c) <> '';

CREATE TABLE socio_clase (
    id_socio      integer     NOT NULL REFERENCES socio_nuevo (id_socio),
    nombre_clase  varchar(40) NOT NULL REFERENCES clase (nombre_clase),
    PRIMARY KEY (id_socio, nombre_clase)
);
INSERT INTO socio_clase
SELECT DISTINCT s.id_socio, initcap(trim(c))
FROM socio s, string_to_table(s.clases, ';') AS c
WHERE trim(c) <> '';

-- (e) Verificacion, antes de borrar la tabla vieja
SELECT 'plan' AS tabla, 3 AS esperado, count(*) AS obtenido FROM plan
UNION ALL SELECT 'socio',       6, count(*) FROM socio_nuevo
UNION ALL SELECT 'clase',       5, count(*) FROM clase
UNION ALL SELECT 'socio_clase', 9, count(*) FROM socio_clase;

-- datos del socio viejo vs nuevo (las dos deben dar 0 filas)
SELECT id_socio, nombre, plan, valor_plan FROM socio
EXCEPT
SELECT s.id_socio, s.nombre, s.plan, p.valor_plan
FROM socio_nuevo s JOIN plan p ON p.plan = s.plan;

SELECT s.id_socio, s.nombre, s.plan, p.valor_plan
FROM socio_nuevo s JOIN plan p ON p.plan = s.plan
EXCEPT
SELECT id_socio, nombre, plan, valor_plan FROM socio;

-- clases de cada socio viejo vs socio_clase (las dos deben dar 0 filas)
SELECT s.id_socio, initcap(trim(c))
FROM socio s, string_to_table(s.clases, ';') AS c
WHERE trim(c) <> ''
EXCEPT
SELECT id_socio, nombre_clase FROM socio_clase;

SELECT id_socio, nombre_clase FROM socio_clase
EXCEPT
SELECT s.id_socio, initcap(trim(c))
FROM socio s, string_to_table(s.clases, ';') AS c
WHERE trim(c) <> '';

DROP TABLE socio;
ALTER TABLE socio_nuevo RENAME TO socio;

COMMIT;

-- ahora el conteo sale bien: Yoga 3, Spinning 2, Spinning Avanzado 1
SELECT nombre_clase, count(*) AS socios
FROM socio_clase
GROUP BY nombre_clase
ORDER BY nombre_clase;

-- Pregunta propia
-- Si el gimnasio quiere guardar el horario de cada clase (dia y hora),
-- ¿en que tabla va y por que no se podia con el diseño original?
--
-- Va en clase, porque el horario depende de la clase y no del socio:
--   ALTER TABLE clase ADD COLUMN dia varchar(10), ADD COLUMN hora time;
-- Si una clase tiene varios horarios se haria otra tabla
-- clase_horario (nombre_clase, dia, hora) con PK de las tres.
--
-- Con el diseño original no se podia porque no habia una tabla de clases,
-- las clases eran texto dentro del socio, entonces no habia donde poner el
-- horario de Yoga. Si se ponia en socio se repetiria en cada socio, y un
-- socio con 3 clases tendria 3 horarios en una celda (otra vez sin 1FN).
-- Y como no habia FK, 'yoga' y 'Yoga ' podian terminar con horarios distintos.


-- #####################################################################
-- CASO 2: FARMACIA
-- #####################################################################
SET search_path TO farmacia;

-- (a) Diagnostico
-- Queja: el medico receto 4 medicamentos y el sistema solo deja 3, y para
-- saber cuantas formulas tienen acetaminofen toca buscar en 3 columnas.
--
-- Dependencias:
--   num_formula -> fecha, doc_paciente
--   doc_paciente -> nombre_paciente
--   num_formula, medicamento -> dosis
--   un medicamento no se repite en la misma formula
--
-- El problema principal es el grupo repetido medicamento1..3 / dosis1..3,
-- no esta en 1FN. Solo caben 3, quedan muchos NULL y para buscar un
-- medicamento hay que mirar las tres columnas.
--
-- Tambien falla 3FN: num_formula -> doc_paciente -> nombre_paciente. El
-- nombre se repite en cada formula (Rosa Diaz sale 2 veces) y no se puede
-- registrar un paciente sin formula.

-- (b) Evidencia

-- buscando en las tres columnas da 3 (701, 703, 704)
SELECT count(*) AS formulas_con_acetaminofen
FROM formula
WHERE medicamento1 LIKE 'Acetaminofén%'
   OR medicamento2 LIKE 'Acetaminofén%'
   OR medicamento3 LIKE 'Acetaminofén%';

-- si se olvida medicamento3 da 2, se pierde la 703
SELECT count(*) AS olvidando_medicamento3
FROM formula
WHERE medicamento1 LIKE 'Acetaminofén%'
   OR medicamento2 LIKE 'Acetaminofén%';

-- cuantos medicamentos tiene cada formula (solo la 703 usa las 3)
SELECT num_formula,
       (medicamento1 IS NOT NULL)::int + (medicamento2 IS NOT NULL)::int
       + (medicamento3 IS NOT NULL)::int AS medicamentos
FROM formula ORDER BY num_formula;

-- nombre del paciente repetido
SELECT doc_paciente, nombre_paciente, count(*) AS veces
FROM formula GROUP BY doc_paciente, nombre_paciente ORDER BY veces DESC;

-- revisar doc_paciente -> nombre_paciente (debe dar 0 filas)
SELECT doc_paciente FROM formula
GROUP BY doc_paciente HAVING count(DISTINCT nombre_paciente) > 1;

-- (c) Esquema corregido
--   paciente (doc_paciente PK, nombre_paciente)
--   formula (num_formula PK, fecha, doc_paciente FK)
--   formula_medicamento (num_formula FK, medicamento, dosis,
--                        PK (num_formula, medicamento))

-- (d) Migracion
-- esperados: 8 medicamentos, 4 formulas, 3 pacientes
SELECT count(medicamento1) + count(medicamento2) + count(medicamento3)
                                AS medicamentos_esperados,
       count(*)                 AS formulas_esperadas,
       count(DISTINCT doc_paciente) AS pacientes_esperados
FROM formula;

BEGIN;

ALTER TABLE formula RENAME TO formula_vieja;

CREATE TABLE paciente (
    doc_paciente     varchar(15) PRIMARY KEY,
    nombre_paciente  varchar(80) NOT NULL
);

CREATE TABLE formula (
    num_formula   integer     PRIMARY KEY,
    fecha         date        NOT NULL,
    doc_paciente  varchar(15) NOT NULL REFERENCES paciente (doc_paciente)
);

CREATE TABLE formula_medicamento (
    num_formula  integer     NOT NULL REFERENCES formula (num_formula),
    medicamento  varchar(60) NOT NULL,
    dosis        varchar(40) NOT NULL,
    PRIMARY KEY (num_formula, medicamento)
);

INSERT INTO paciente
SELECT DISTINCT doc_paciente, nombre_paciente FROM formula_vieja;

INSERT INTO formula
SELECT num_formula, fecha, doc_paciente FROM formula_vieja;

-- pasar las columnas numeradas a filas
INSERT INTO formula_medicamento
SELECT num_formula, medicamento1, dosis1 FROM formula_vieja WHERE medicamento1 IS NOT NULL
UNION ALL
SELECT num_formula, medicamento2, dosis2 FROM formula_vieja WHERE medicamento2 IS NOT NULL
UNION ALL
SELECT num_formula, medicamento3, dosis3 FROM formula_vieja WHERE medicamento3 IS NOT NULL;

-- (e) Verificacion
SELECT 'paciente' AS tabla, 3 AS esperado, count(*) AS obtenido FROM paciente
UNION ALL SELECT 'formula',             4, count(*) FROM formula
UNION ALL SELECT 'formula_medicamento', 8, count(*) FROM formula_medicamento;

-- encabezado viejo vs nuevo (0 filas)
SELECT num_formula, fecha, doc_paciente, nombre_paciente FROM formula_vieja
EXCEPT
SELECT f.num_formula, f.fecha, f.doc_paciente, p.nombre_paciente
FROM formula f JOIN paciente p ON p.doc_paciente = f.doc_paciente;

-- medicamentos viejos vs nuevos en los dos sentidos (0 filas)
WITH viejos AS (
    SELECT num_formula, medicamento1 AS medicamento, dosis1 AS dosis FROM formula_vieja WHERE medicamento1 IS NOT NULL
    UNION ALL
    SELECT num_formula, medicamento2, dosis2 FROM formula_vieja WHERE medicamento2 IS NOT NULL
    UNION ALL
    SELECT num_formula, medicamento3, dosis3 FROM formula_vieja WHERE medicamento3 IS NOT NULL
)
(SELECT * FROM viejos EXCEPT SELECT * FROM formula_medicamento)
UNION ALL
(SELECT * FROM formula_medicamento EXCEPT SELECT * FROM viejos);

DROP TABLE formula_vieja;

COMMIT;

-- ahora se busca en una sola columna (da 3)
SELECT count(DISTINCT num_formula) AS formulas_con_acetaminofen
FROM formula_medicamento
WHERE medicamento LIKE 'Acetaminofén%';

-- prueba de que ya caben 4 medicamentos (con rollback)
BEGIN;
INSERT INTO formula_medicamento VALUES
    (702, 'Ibuprofeno 400 mg', 'cada 12 h'),
    (702, 'Omeprazol 20 mg',   'cada 24 h'),
    (702, 'Loratadina 10 mg',  'cada 24 h');
SELECT * FROM formula_medicamento WHERE num_formula = 702;
ROLLBACK;

-- la PK no deja repetir un medicamento en la misma formula
DO $$
BEGIN
    INSERT INTO formula_medicamento VALUES (701, 'Loratadina 10 mg', 'cada 12 h');
    RAISE NOTICE 'se acepto el medicamento repetido (mal)';
EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'la base no dejo repetir el medicamento en la 701';
END $$;

-- Pregunta propia
-- ¿Por que no sirve solo agregar medicamento4 y dosis4?
-- Porque el limite pasa de 3 a 4 y cuando receten 5 toca cambiar la tabla
-- otra vez y todo lo que la use. Las consultas tienen que revisar todas las
-- columnas y si a alguien se le olvida una da mal sin avisar (como arriba,
-- que da 2 en vez de 3). Seria otra columna casi siempre en NULL, porque hoy
-- solo la 703 usa las 3. Y nada impide poner el mismo medicamento en dos
-- columnas, en cambio con formula_medicamento la PK lo rechaza.


-- #####################################################################
-- CASO 3: CURSOS LIBRES
-- #####################################################################
SET search_path TO cursos_libres;

-- (a) Diagnostico
-- Queja: contabilidad dice que Fotografia digital recaudo 200 000 mas de lo
-- que hay en caja.
--
-- Dependencias:
--   doc_participante -> nombre_participante, correo
--   correo -> doc_participante
--   cod_curso -> nombre_curso, cod_sede
--   cod_sede -> direccion_sede
--   doc_participante, cod_curso -> valor_pagado
--   (el valor puede tener descuento, en C20 hay 200 000 y 180 000)
--
-- El problema principal es que la tabla usa un id serial pero no tiene
-- UNIQUE en (doc_participante, cod_curso). Las filas 3 y 7 son la misma
-- inscripcion de Juliana Rey en C20 y se suma dos veces.
--
-- Ademas no esta en 2FN ni 3FN. (doc_participante, cod_curso) es clave
-- candidata aunque no este declarada, y hay dependencias parciales
-- (doc_participante -> nombre, correo y cod_curso -> nombre_curso, cod_sede)
-- y una transitiva (cod_sede -> direccion_sede). Juliana sale en 3 filas y la
-- direccion de S1 en 5.

-- (b) Evidencia

-- tabla inicial, las filas 3 y 7 son iguales menos el id
SELECT * FROM inscripcion ORDER BY id;

-- Fotografia digital da 580 000, deberia ser 380 000
SELECT cod_curso, nombre_curso, sum(valor_pagado) AS recaudo_actual
FROM inscripcion GROUP BY cod_curso, nombre_curso ORDER BY cod_curso;

-- la inscripcion repetida (1140000900, C20, 2 veces)
SELECT doc_participante, cod_curso, count(*) AS veces
FROM inscripcion GROUP BY doc_participante, cod_curso HAVING count(*) > 1;

-- participantes repetidos
SELECT doc_participante, nombre_participante, correo, count(*) AS veces
FROM inscripcion
GROUP BY doc_participante, nombre_participante, correo
ORDER BY veces DESC;

-- sedes repetidas
SELECT cod_sede, direccion_sede, count(*) AS veces
FROM inscripcion GROUP BY cod_sede, direccion_sede ORDER BY veces DESC;

-- revisar las dependencias, todas deben dar 0 filas
SELECT doc_participante FROM inscripcion GROUP BY doc_participante
HAVING count(DISTINCT nombre_participante) > 1 OR count(DISTINCT correo) > 1;

SELECT correo FROM inscripcion GROUP BY correo
HAVING count(DISTINCT doc_participante) > 1;

SELECT cod_curso FROM inscripcion GROUP BY cod_curso
HAVING count(DISTINCT nombre_curso) > 1 OR count(DISTINCT cod_sede) > 1;

SELECT cod_sede FROM inscripcion GROUP BY cod_sede
HAVING count(DISTINCT direccion_sede) > 1;

-- Como las filas 3 y 7 son iguales asumimos que Juliana pago una sola vez
-- (habria que confirmarlo con caja). El SELECT DISTINCT deja solo una, por
-- eso esperamos 7 inscripciones y no 8.

-- (c) Esquema corregido
--   sede (cod_sede PK, direccion_sede)
--   participante (doc_participante PK, nombre_participante, correo UNIQUE)
--   curso (cod_curso PK, nombre_curso, cod_sede FK)
--   inscripcion (doc_participante FK, cod_curso FK, valor_pagado,
--                PK (doc_participante, cod_curso))

-- (d) Migracion
-- esperados: 2 sedes, 4 participantes, 3 cursos, 7 inscripciones
SELECT count(DISTINCT cod_sede)                       AS sedes_esperadas,
       count(DISTINCT doc_participante)               AS participantes_esperados,
       count(DISTINCT cod_curso)                      AS cursos_esperados,
       count(DISTINCT (doc_participante, cod_curso))  AS inscripciones_esperadas
FROM inscripcion;

BEGIN;

ALTER TABLE inscripcion RENAME TO inscripcion_vieja;

CREATE TABLE sede (
    cod_sede        char(2)     PRIMARY KEY,
    direccion_sede  varchar(60) NOT NULL
);

CREATE TABLE participante (
    doc_participante     varchar(15)  PRIMARY KEY,
    nombre_participante  varchar(80)  NOT NULL,
    correo               varchar(120) NOT NULL UNIQUE
);

CREATE TABLE curso (
    cod_curso     char(3)     PRIMARY KEY,
    nombre_curso  varchar(60) NOT NULL,
    cod_sede      char(2)     NOT NULL REFERENCES sede (cod_sede)
);

CREATE TABLE inscripcion (
    doc_participante  varchar(15) NOT NULL REFERENCES participante (doc_participante),
    cod_curso         char(3)     NOT NULL REFERENCES curso (cod_curso),
    valor_pagado      integer     NOT NULL,
    PRIMARY KEY (doc_participante, cod_curso)
);

INSERT INTO sede         SELECT DISTINCT cod_sede, direccion_sede FROM inscripcion_vieja;
INSERT INTO participante SELECT DISTINCT doc_participante, nombre_participante, correo FROM inscripcion_vieja;
INSERT INTO curso        SELECT DISTINCT cod_curso, nombre_curso, cod_sede FROM inscripcion_vieja;
INSERT INTO inscripcion  SELECT DISTINCT doc_participante, cod_curso, valor_pagado FROM inscripcion_vieja;

-- (e) Verificacion
-- la vieja tenia 8 filas, la que falta es el duplicado
SELECT 'sede' AS tabla, 2 AS esperado, count(*) AS obtenido FROM sede
UNION ALL SELECT 'participante', 4, count(*) FROM participante
UNION ALL SELECT 'curso',        3, count(*) FROM curso
UNION ALL SELECT 'inscripcion',  7, count(*) FROM inscripcion;

CREATE VIEW reconstruida AS
SELECT i.doc_participante, p.nombre_participante, p.correo,
       i.cod_curso, c.nombre_curso, c.cod_sede, s.direccion_sede, i.valor_pagado
FROM inscripcion i
JOIN participante p ON p.doc_participante = i.doc_participante
JOIN curso c        ON c.cod_curso        = i.cod_curso
JOIN sede s         ON s.cod_sede         = c.cod_sede;

-- vieja vs reconstruida (las dos 0 filas)
SELECT doc_participante, nombre_participante, correo, cod_curso, nombre_curso,
       cod_sede, direccion_sede, valor_pagado
FROM inscripcion_vieja
EXCEPT
SELECT * FROM reconstruida;

SELECT * FROM reconstruida
EXCEPT
SELECT doc_participante, nombre_participante, correo, cod_curso, nombre_curso,
       cod_sede, direccion_sede, valor_pagado
FROM inscripcion_vieja;

-- recaudo corregido: C10 450000, C20 380000, C30 340000
SELECT c.cod_curso, c.nombre_curso, sum(i.valor_pagado) AS recaudo
FROM inscripcion i JOIN curso c ON c.cod_curso = i.cod_curso
GROUP BY c.cod_curso, c.nombre_curso ORDER BY c.cod_curso;

DROP VIEW reconstruida;
DROP TABLE inscripcion_vieja;

COMMIT;

-- probar que ya no deja meter el duplicado
DO $$
BEGIN
    INSERT INTO inscripcion VALUES ('1140000900', 'C20', 200000);
    RAISE NOTICE 'se acepto el duplicado (mal)';
EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'la base no dejo meter la inscripcion repetida';
END $$;

-- Pregunta propia
-- La tabla tiene PK de una sola columna, ¿por que no queda en 2FN?
-- Porque la 2FN se revisa con todas las claves candidatas y no solo con la
-- PK. Como un participante solo se inscribe una vez por curso,
-- (doc_participante, cod_curso) es clave candidata, y hay datos que dependen
-- solo de una parte de esa clave (nombre y correo del participante, nombre y
-- sede del curso). Ponerle un id no arregla eso.
--
-- ¿Que restriccion faltaba?
-- UNIQUE (doc_participante, cod_curso). Con eso la base no hubiera dejado
-- registrar dos veces a Juliana en Fotografia digital y el recaudo no habria
-- salido con 200 000 de mas.


-- #####################################################################
-- CASO 4: ENVIOS
-- #####################################################################
SET search_path TO envios;

-- (a) Diagnostico
-- Queja: un cliente de Bogota dice que le cobraron de mas.
--
-- Dependencias:
--   num_guia -> fecha, ciudad_destino, peso_kg
--   ciudad_destino -> departamento, zona
--   zona -> tarifa_kg
--   valor = peso_kg * tarifa_kg
--
-- El problema principal es que valor es un dato calculado que se guarda. Se
-- puede sacar con peso_kg * tarifa_kg, pero como se guarda aparte nada
-- asegura que cuadre, y en G07 (Bogota) quedo 42 000 cuando era 24 000.
--
-- Tambien falla 3FN por las transitivas:
--   num_guia -> ciudad_destino -> departamento, zona
--   num_guia -> ciudad_destino -> zona -> tarifa_kg
-- Los datos de la ciudad se repiten en cada envio, para subir la tarifa de la
-- zona 2 toca cambiar 4 filas, no se puede crear la zona 4 sin un envio, y si
-- se borran los envios a Pasto se pierde su zona y tarifa.

-- (b) Evidencia

-- envios donde el valor guardado no cuadra (sale G07: 42000 vs 24000)
SELECT num_guia, ciudad_destino, peso_kg, tarifa_kg, valor,
       peso_kg * tarifa_kg         AS valor_calculado,
       valor - peso_kg * tarifa_kg AS diferencia
FROM envio
WHERE valor <> peso_kg * tarifa_kg;

-- datos de ciudad y zona repetidos
SELECT ciudad_destino, departamento, zona, tarifa_kg, count(*) AS veces
FROM envio
GROUP BY ciudad_destino, departamento, zona, tarifa_kg
ORDER BY veces DESC;

-- revisar ciudad -> departamento, zona (0 filas)
SELECT ciudad_destino FROM envio GROUP BY ciudad_destino
HAVING count(DISTINCT departamento) > 1 OR count(DISTINCT zona) > 1;

-- revisar zona -> tarifa_kg (0 filas)
SELECT zona FROM envio GROUP BY zona HAVING count(DISTINCT tarifa_kg) > 1;

-- anomalia de actualizacion (con rollback): la zona 2 queda con dos tarifas
BEGIN;
UPDATE envio SET tarifa_kg = 6500 WHERE num_guia = 'G03';
SELECT zona, count(DISTINCT tarifa_kg) AS tarifas_distintas,
       string_agg(DISTINCT tarifa_kg::text, ', ') AS tarifas
FROM envio GROUP BY zona ORDER BY zona;
ROLLBACK;

-- anomalia de insercion: no se puede crear la zona 4 sola
DO $$
BEGIN
    INSERT INTO envio (zona, tarifa_kg) VALUES (4, 12000);
    RAISE NOTICE 'se pudo crear la zona 4 sola';
EXCEPTION WHEN not_null_violation THEN
    RAISE NOTICE 'no se puede crear la zona 4 sin los datos de un envio';
END $$;

-- Sobre G07: 42000 / 6000 = 7 kg, asi que el error podia ser el peso o el
-- valor. Pero el cliente dice que le cobraron de mas, o sea que el peso de
-- 4 kg esta bien y lo malo es el valor. Como en el esquema nuevo el valor se
-- calcula, eso se corrige solo.

-- (c) Esquema corregido
--   zona (zona PK, tarifa_kg)
--   ciudad (nombre PK, departamento, zona FK)
--   envio (num_guia PK, fecha, ciudad_destino FK, peso_kg)
--   vista envio_con_valor que calcula el valor

-- (d) Migracion
-- esperados: 3 zonas, 5 ciudades, 8 envios
SELECT count(DISTINCT zona)           AS zonas_esperadas,
       count(DISTINCT ciudad_destino) AS ciudades_esperadas,
       count(*)                       AS envios_esperados
FROM envio;

BEGIN;

CREATE TABLE zona (
    zona       smallint PRIMARY KEY,
    tarifa_kg  integer  NOT NULL CHECK (tarifa_kg > 0)
);

CREATE TABLE ciudad (
    nombre        varchar(40) PRIMARY KEY,
    departamento  varchar(40) NOT NULL,
    zona          smallint    NOT NULL REFERENCES zona (zona)
);

INSERT INTO zona (zona, tarifa_kg)
SELECT DISTINCT zona, tarifa_kg FROM envio;

INSERT INTO ciudad (nombre, departamento, zona)
SELECT DISTINCT ciudad_destino, departamento, zona FROM envio;

-- (e) Verificacion, antes de borrar columnas
SELECT 'zona' AS tabla, 3 AS esperado, count(*) AS obtenido FROM zona
UNION ALL SELECT 'ciudad', 5, count(*) FROM ciudad;

-- viejo vs reconstruido en los dos sentidos (0 filas).
-- valor no se compara porque es el dato que dejamos de guardar
SELECT num_guia, fecha, ciudad_destino, departamento, zona, tarifa_kg, peso_kg
FROM envio
EXCEPT
SELECT e.num_guia, e.fecha, e.ciudad_destino, c.departamento, c.zona, z.tarifa_kg, e.peso_kg
FROM envio e
JOIN ciudad c ON c.nombre = e.ciudad_destino
JOIN zona   z ON z.zona   = c.zona;

SELECT e.num_guia, e.fecha, e.ciudad_destino, c.departamento, c.zona, z.tarifa_kg, e.peso_kg
FROM envio e
JOIN ciudad c ON c.nombre = e.ciudad_destino
JOIN zona   z ON z.zona   = c.zona
EXCEPT
SELECT num_guia, fecha, ciudad_destino, departamento, zona, tarifa_kg, peso_kg
FROM envio;

-- quitar columnas viejas y conectar envio con ciudad
ALTER TABLE envio
    ADD FOREIGN KEY (ciudad_destino) REFERENCES ciudad (nombre),
    ADD CHECK (peso_kg > 0),
    DROP COLUMN departamento,
    DROP COLUMN zona,
    DROP COLUMN tarifa_kg,
    DROP COLUMN valor;

-- vista con el valor calculado
CREATE VIEW envio_con_valor AS
SELECT e.num_guia, e.fecha, e.ciudad_destino, c.departamento, c.zona,
       z.tarifa_kg, e.peso_kg,
       round(e.peso_kg * z.tarifa_kg)::integer AS valor
FROM envio e
JOIN ciudad c ON c.nombre = e.ciudad_destino
JOIN zona   z ON z.zona   = c.zona;

-- conteos finales: 3, 5, 8, 8
SELECT (SELECT count(*) FROM zona)            AS zonas,
       (SELECT count(*) FROM ciudad)          AS ciudades,
       (SELECT count(*) FROM envio)           AS envios,
       (SELECT count(*) FROM envio_con_valor) AS en_vista;

COMMIT;

-- G07 ahora da 24 000
SELECT num_guia, fecha, peso_kg, tarifa_kg, valor
FROM envio_con_valor
WHERE ciudad_destino = 'Bogotá'
ORDER BY num_guia;

-- ya se puede crear una zona sin envios (con rollback)
BEGIN;
INSERT INTO zona VALUES (4, 12000);
SELECT * FROM zona ORDER BY zona;
ROLLBACK;

-- Pregunta propia
-- Si en enero sube la tarifa de la zona 2, ¿que pasa con los envios de
-- octubre? (prueba con rollback)
BEGIN;
UPDATE zona SET tarifa_kg = 6500 WHERE zona = 2;
SELECT num_guia, fecha, peso_kg, tarifa_kg, valor
FROM envio_con_valor WHERE zona = 2 ORDER BY num_guia;
ROLLBACK;

-- G07 pasa a 26 000 aunque se cobro con la tarifa de octubre. La vista usa
-- la tarifa actual, entonces todos los envios viejos de esa zona cambian de
-- valor y las facturas pasadas quedan mal.
--
-- Lo que cambiariamos es guardar en envio la tarifa que se cobro ese dia:
--   ALTER TABLE envio ADD COLUMN tarifa_aplicada integer;
-- y calcular el valor con peso_kg * tarifa_aplicada. Otra opcion es una tabla
-- zona_tarifa (zona, vigente_desde, tarifa_kg) con el historial.
--
-- ¿Eso es redundancia? No. La tarifa_kg de antes dependia de la zona, era
-- una copia. tarifa_aplicada depende del envio, es lo que se cobro ese dia.
-- Despues de enero la zona 2 vale 6500 y G07 sigue con 6000 y las dos cosas
-- son correctas, entonces ya no hay zona -> tarifa_aplicada y sigue en 3FN.
-- La diferencia es que un dato calculado siempre se puede volver a sacar,
-- pero uno historico no, si no se guarda se pierde.
