//! Optimización del orden de visita de paradas (el "problema del viajante").
//!
//! Problema: tienes un hotel y 8 sitios que ver. ¿En qué orden los visitas
//! para andar lo menos posible? Con 8 paradas hay 5.040 órdenes posibles; con
//! 20, más de 10^17. Probarlos todos es imposible a partir de cierto tamaño.
//!
//! Estrategia en dos niveles:
//! - **Pocas paradas (hasta `exact_max_stops`, 12 por defecto):** algoritmo
//!   exacto de Held-Karp (programación dinámica). Garantiza el mejor orden.
//!   Coste ~ n²·2ⁿ: con 12 paradas son unos pocos millones de operaciones (ms).
//! - **Muchas paradas:** heurística en dos pasos: "vecino más cercano" (ir
//!   siempre al sitio más próximo aún sin visitar) y luego "2-opt" (deshacer
//!   cruces: si dos tramos del recorrido se cruzan, invertir el trozo entre
//!   ellos siempre lo acorta). No garantiza el óptimo, pero suele quedar a
//!   pocos puntos porcentuales y su coste está acotado.
//!
//! Todo es determinista: la misma entrada da siempre la misma salida. Eso hace
//! que el resultado se pueda cachear y que reintentar una petición sea seguro.

use super::coord::LatLng;

/// Forma del recorrido.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RouteShape {
    /// Empieza en la primera parada y acaba en cualquiera.
    Open,
    /// Empieza y acaba en la primera parada.
    RoundTrip,
}

/// Resultado de la optimización.
#[derive(Debug, Clone, PartialEq)]
pub struct RoutePlan {
    /// Índices de las paradas (de la entrada) en orden de visita. Siempre
    /// empieza por 0. En un recorrido circular la vuelta a 0 está implícita.
    pub order: Vec<usize>,
    /// Distancia de cada tramo en metros (incluye la vuelta si es circular).
    pub leg_distances_m: Vec<f64>,
    /// Suma de los tramos.
    pub total_distance_m: f64,
    /// true si el orden es el óptimo garantizado.
    pub optimal: bool,
}

/// Límite superior absoluto para el algoritmo exacto: 2^15 · 15 estados
/// (~490.000 valores f64, ~4 MB). Más allá, la memoria crece demasiado.
pub const EXACT_HARD_LIMIT: usize = 15;

/// Máximo de pasadas completas de 2-opt: acota el tiempo de CPU en el peor caso.
const MAX_TWO_OPT_PASSES: usize = 64;

/// Calcula el mejor orden de visita. `stops` no puede estar vacío (lo
/// garantiza la validación de la API); si lo está, devuelve un plan vacío.
pub fn optimize(stops: &[LatLng], shape: RouteShape, exact_max_stops: usize) -> RoutePlan {
    let n = stops.len();
    if n == 0 {
        return RoutePlan { order: Vec::new(), leg_distances_m: Vec::new(), total_distance_m: 0.0, optimal: true };
    }
    let matrix = DistanceMatrix::new(stops);
    // Con 3 paradas o menos (y la primera fija) solo hay 1 o 2 órdenes
    // posibles: siempre se resuelve de forma exacta, al instante.
    let exact_limit = exact_max_stops.clamp(3, EXACT_HARD_LIMIT);
    let (order, optimal) = if n <= exact_limit {
        (held_karp(&matrix, shape), true)
    } else {
        let mut tour = nearest_neighbour(&matrix);
        two_opt(&matrix, &mut tour, shape);
        (tour, false)
    };
    plan_from_order(&matrix, order, shape, optimal)
}

/// Distancias geodésicas entre todos los pares de paradas, calculadas una vez.
/// Se guarda en un único vector (fila tras fila): más rápido que un Vec<Vec<f64>>.
struct DistanceMatrix {
    n: usize,
    values: Vec<f64>,
}

impl DistanceMatrix {
    fn new(stops: &[LatLng]) -> Self {
        let n = stops.len();
        let mut values = vec![0.0; n * n];
        for i in 0..n {
            for j in (i + 1)..n {
                // La distancia de A a B es la misma que de B a A: calculamos la mitad.
                let d = stops[i].geodesic_distance_m(stops[j]);
                values[i * n + j] = d;
                values[j * n + i] = d;
            }
        }
        Self { n, values }
    }

    fn get(&self, from: usize, to: usize) -> f64 {
        self.values[from * self.n + to]
    }
}

/// Held-Karp: dp[S][j] = distancia mínima saliendo de 0, visitando el
/// conjunto S de paradas y terminando en j. Cada conjunto S se representa con
/// los bits de un número (bit k = "la parada k+1 está en S").
fn held_karp(m: &DistanceMatrix, shape: RouteShape) -> Vec<usize> {
    let n = m.n;
    if n == 1 {
        return vec![0];
    }
    let k = n - 1; // paradas libres (la 0 es la salida fija)
    let full = (1usize << k) - 1;
    let mut dp = vec![f64::INFINITY; (1 << k) * k];
    let mut parent = vec![usize::MAX; (1 << k) * k];
    for j in 0..k {
        dp[(1 << j) * k + j] = m.get(0, j + 1);
    }
    for set in 1..=full {
        for last in 0..k {
            if set & (1 << last) == 0 {
                continue;
            }
            let current = dp[set * k + last];
            if !current.is_finite() {
                continue;
            }
            for next in 0..k {
                if set & (1 << next) != 0 {
                    continue;
                }
                let next_set = set | (1 << next);
                let candidate = current + m.get(last + 1, next + 1);
                let slot = next_set * k + next;
                if candidate < dp[slot] {
                    dp[slot] = candidate;
                    parent[slot] = last;
                }
            }
        }
    }
    // Elegir el mejor final (sumando la vuelta a 0 si es circular). En caso de
    // empate gana el índice más bajo: determinista.
    let closing = |last: usize| match shape {
        RouteShape::Open => 0.0,
        RouteShape::RoundTrip => m.get(last + 1, 0),
    };
    let mut best_last = 0;
    let mut best_cost = f64::INFINITY;
    for last in 0..k {
        let cost = dp[full * k + last] + closing(last);
        if cost < best_cost {
            best_cost = cost;
            best_last = last;
        }
    }
    // Reconstruir el camino hacia atrás siguiendo "parent".
    let mut order = Vec::with_capacity(n);
    let mut set = full;
    let mut last = best_last;
    while last != usize::MAX {
        order.push(last + 1);
        let previous = parent[set * k + last];
        set &= !(1 << last);
        last = previous;
    }
    order.push(0);
    order.reverse();
    order
}

/// Vecino más cercano: desde la salida, ir siempre a la parada sin visitar
/// más próxima.
fn nearest_neighbour(m: &DistanceMatrix) -> Vec<usize> {
    let mut visited = vec![false; m.n];
    let mut tour = Vec::with_capacity(m.n);
    let mut current = 0;
    visited[0] = true;
    tour.push(0);
    for _ in 1..m.n {
        let mut best: Option<(usize, f64)> = None;
        for (candidate, seen) in visited.iter().enumerate() {
            if *seen {
                continue;
            }
            let d = m.get(current, candidate);
            if best.is_none_or(|(_, best_d)| d < best_d) {
                best = Some((candidate, d));
            }
        }
        let Some((next, _)) = best else { break };
        visited[next] = true;
        tour.push(next);
        current = next;
    }
    tour
}

/// 2-opt: probar a invertir cada tramo tour[i..=j]; si acorta, se aplica.
/// Solo cambian los dos "bordes" del tramo, así que el ahorro se calcula en
/// O(1) sin recorrer toda la ruta.
fn two_opt(m: &DistanceMatrix, tour: &mut [usize], shape: RouteShape) {
    let n = tour.len();
    if n < 4 {
        return;
    }
    // Distancia desde el final del tramo invertido hasta lo que venga después
    // (nada si la ruta es abierta y el tramo llega al final).
    let after = |tour: &[usize], node: usize, j: usize| -> f64 {
        if j + 1 < n {
            m.get(node, tour[j + 1])
        } else {
            match shape {
                RouteShape::Open => 0.0,
                RouteShape::RoundTrip => m.get(node, tour[0]),
            }
        }
    };
    for _ in 0..MAX_TWO_OPT_PASSES {
        let mut improved = false;
        for i in 1..(n - 1) {
            for j in (i + 1)..n {
                let before = m.get(tour[i - 1], tour[i]) + after(tour, tour[j], j);
                let changed = m.get(tour[i - 1], tour[j]) + after(tour, tour[i], j);
                // El margen evita bucles infinitos por errores de redondeo.
                if changed + 1e-6 < before {
                    tour[i..=j].reverse();
                    improved = true;
                }
            }
        }
        if !improved {
            break;
        }
    }
}

fn plan_from_order(m: &DistanceMatrix, order: Vec<usize>, shape: RouteShape, optimal: bool) -> RoutePlan {
    let mut legs: Vec<f64> = order.windows(2).map(|w| m.get(w[0], w[1])).collect();
    if shape == RouteShape::RoundTrip
        && order.len() > 1
        && let (Some(&last), Some(&first)) = (order.last(), order.first())
    {
        legs.push(m.get(last, first));
    }
    let total = legs.iter().sum();
    RoutePlan { order, leg_distances_m: legs, total_distance_m: total, optimal }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spatial::index::tests::ll;

    /// Fuerza bruta (todas las permutaciones) para comprobar el algoritmo exacto.
    fn brute_force_cost(stops: &[LatLng], shape: RouteShape) -> f64 {
        fn permute(rest: &mut Vec<usize>, k: usize, out: &mut Vec<Vec<usize>>) {
            if k == rest.len() {
                out.push(rest.clone());
                return;
            }
            for i in k..rest.len() {
                rest.swap(k, i);
                permute(rest, k + 1, out);
                rest.swap(k, i);
            }
        }
        let m = DistanceMatrix::new(stops);
        let mut perms = Vec::new();
        permute(&mut (1..stops.len()).collect(), 0, &mut perms);
        perms
            .into_iter()
            .map(|p| {
                let mut order = vec![0];
                order.extend(p);
                plan_from_order(&m, order, shape, true).total_distance_m
            })
            .fold(f64::INFINITY, f64::min)
    }

    fn madrid_stops() -> Vec<LatLng> {
        vec![
            ll(40.4168, -3.7038), // Sol (salida)
            ll(40.4138, -3.6921), // Prado
            ll(40.4180, -3.7144), // Palacio Real
            ll(40.4153, -3.6845), // Retiro
            ll(40.4240, -3.7117), // Templo de Debod
            ll(40.4086, -3.6944), // Reina Sofía
            ll(40.4155, -3.7074), // Plaza Mayor
            ll(40.4200, -3.7055), // Gran Vía
        ]
    }

    #[test]
    fn exacto_coincide_con_fuerza_bruta() {
        let stops = madrid_stops();
        for shape in [RouteShape::Open, RouteShape::RoundTrip] {
            let plan = optimize(&stops, shape, 12);
            assert!(plan.optimal);
            assert_eq!(plan.order[0], 0, "siempre se sale de la primera parada");
            let mut sorted = plan.order.clone();
            sorted.sort_unstable();
            assert_eq!(sorted, (0..stops.len()).collect::<Vec<_>>(), "cada parada exactamente una vez");
            let best = brute_force_cost(&stops, shape);
            assert!((plan.total_distance_m - best).abs() < 1e-6, "{shape:?}: {} vs {best}", plan.total_distance_m);
        }
    }

    #[test]
    fn tramos_cuadran_con_el_total() {
        let plan = optimize(&madrid_stops(), RouteShape::RoundTrip, 12);
        assert_eq!(plan.leg_distances_m.len(), plan.order.len());
        let sum: f64 = plan.leg_distances_m.iter().sum();
        assert!((sum - plan.total_distance_m).abs() < 1e-6);
        let open = optimize(&madrid_stops(), RouteShape::Open, 12);
        assert_eq!(open.leg_distances_m.len(), open.order.len() - 1);
    }

    #[test]
    fn heuristica_cerca_del_optimo_y_valida() {
        let stops = madrid_stops();
        for shape in [RouteShape::Open, RouteShape::RoundTrip] {
            // exact_max_stops = 3 obliga a usar la heurística con 8 paradas.
            let plan = optimize(&stops, shape, 3);
            assert!(!plan.optimal);
            let mut sorted = plan.order.clone();
            sorted.sort_unstable();
            assert_eq!(sorted, (0..stops.len()).collect::<Vec<_>>());
            let best = brute_force_cost(&stops, shape);
            assert!(plan.total_distance_m <= best * 1.10, "{shape:?}: {} vs {best}", plan.total_distance_m);
        }
    }

    #[test]
    fn heuristica_con_muchas_paradas_es_rapida_y_determinista() {
        // 150 puntos en una rejilla irregular alrededor de Madrid.
        let stops: Vec<_> = (0..150)
            .map(|i| {
                let f = f64::from(i);
                ll(40.40 + (f * 0.6180339).fract() * 0.05, -3.72 + (f * 0.4142135).fract() * 0.06)
            })
            .collect();
        let started = std::time::Instant::now();
        let a = optimize(&stops, RouteShape::RoundTrip, 12);
        assert!(started.elapsed() < std::time::Duration::from_secs(5));
        let b = optimize(&stops, RouteShape::RoundTrip, 12);
        assert_eq!(a, b, "misma entrada, misma salida");
    }

    #[test]
    fn casos_pequenos() {
        let one = optimize(&[ll(0.0, 0.0)], RouteShape::RoundTrip, 12);
        assert_eq!(one.order, [0]);
        assert!(one.leg_distances_m.is_empty());
        let two = optimize(&[ll(0.0, 0.0), ll(0.0, 1.0)], RouteShape::RoundTrip, 12);
        assert_eq!(two.order, [0, 1]);
        assert_eq!(two.leg_distances_m.len(), 2);
        assert!(optimize(&[], RouteShape::Open, 12).order.is_empty());
    }
}
