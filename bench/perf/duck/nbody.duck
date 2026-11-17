fn main(args: [str]) {
  let steps = int.parse(args[1]) else 1000
  let nb = 5
  var x = [0.0, 4.84, 8.34, 12.89, 15.38]
  var y = [0.0, -1.16, 4.12, -15.11, -25.92]
  var z = [0.0, -0.10, -0.40, -0.22, 0.18]
  var vx = [0.0, 0.606, -1.01, 1.08, 0.979]
  var vy = [0.0, 2.81, 1.82, 0.868, 0.594]
  var vz = [0.0, -0.025, 0.008, -0.010, -0.034]
  let m = [39.47, 0.037, 0.011, 0.0017, 0.002]
  let dt = 0.01
  for _ in 0..steps {
    for i in 0..nb {
      for j in (i + 1)..nb {
        let dx = x[i] - x[j]
        let dy = y[i] - y[j]
        let dz = z[i] - z[j]
        let d2 = dx * dx + dy * dy + dz * dz
        let mag = dt / (d2 * d2.sqrt())
        vx[i] = vx[i] - dx * m[j] * mag
        vy[i] = vy[i] - dy * m[j] * mag
        vz[i] = vz[i] - dz * m[j] * mag
        vx[j] = vx[j] + dx * m[i] * mag
        vy[j] = vy[j] + dy * m[i] * mag
        vz[j] = vz[j] + dz * m[i] * mag
      }
    }
    for i in 0..nb {
      x[i] = x[i] + dt * vx[i]
      y[i] = y[i] + dt * vy[i]
      z[i] = z[i] + dt * vz[i]
    }
  }
  var e = 0.0
  for i in 0..nb { e = e + m[i] * (vx[i] * vx[i] + vy[i] * vy[i] + vz[i] * vz[i]) }
  print("{e:.9}")
}
