# Documentación de trabajo

Material interno del desarrollo de este service, incluido acá para poder revisarlo junto con el
código. **No es documentación de uso**: para eso está el [`README.md`](../README.md) del service.

| Archivo | Qué es |
|---|---|
| [`RUNBOOK-PRUEBAS.md`](./RUNBOOK-PRUEBAS.md) | Prueba paso a paso contra un cluster, con los comandos y su salida esperada |
| [`DISENO.md`](./DISENO.md) | El diseño: qué resuelve, cómo, y los hechos verificados contra cluster |
| [`DECISIONES.md`](./DECISIONES.md) | Las decisiones tomadas durante la implementación, con su motivo y su costo si están mal |
| [`PLAN-IMPLEMENTACION.md`](./PLAN-IMPLEMENTACION.md) | El plan con el que se construyó, tarea por tarea |

El runbook referencia un cluster CRC local, el namespace `payments` y rutas del repo
`nullplatform/galicia-banco`, donde estos documentos viven originalmente. Si esta carpeta estorba en
el entregable, se borra entera sin tocar nada más: ningún archivo del service la referencia.
