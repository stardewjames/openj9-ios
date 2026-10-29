package bench;

import java.util.Arrays;
import java.util.Locale;

/**
 * Entry point for the benchmark app.
 *
 * Output is line-oriented so two runtime runs can be diffed:
 *   BENCH_HOST vm=... version=... os=... arch=... cpus=... heap=... warmupMs=... reps=...
 *   COMPAT <name> <OK|SKIP|FAIL> <detail>
 *   BENCH <name> <median ns/op> <min> <max> batch=<n> ops=<n> checksum=<value>
 *   BENCH_OK
 *
 * Usage: BenchMain [bench|compat|all]
 */
public final class BenchMain {
    public static void main(String[] args) {
        String mode = args.length > 0 ? args[0] : "all";
        int warmupMs = Integer.getInteger("bench.warmupMs", 400);
        int reps = Integer.getInteger("bench.reps", 5);

        System.out.println("BENCH_HOST vm=" + System.getProperty("java.vm.name")
            + " version=" + System.getProperty("java.runtime.version")
            + " os=" + System.getProperty("os.name")
            + " arch=" + System.getProperty("os.arch")
            + " cpus=" + Runtime.getRuntime().availableProcessors()
            + " heap=" + Runtime.getRuntime().maxMemory()
            + " classVersion=" + System.getProperty("java.class.version")
            + " warmupMs=" + warmupMs + " reps=" + reps
            + " mode=" + mode);
        System.out.flush();

        if (mode.equals("compat") || mode.equals("all")) runCompatibility();
        if (mode.equals("bench") || mode.equals("all")) runWorkloads(warmupMs, reps);
        System.out.println("BENCH_OK");
        System.out.flush();
    }

    private static void runCompatibility() {
        Compatibility.run(result ->
            System.out.printf(Locale.ROOT, "COMPAT %s %s %s%n",
                result.name(), result.status(), result.detail()));
        System.out.flush();
    }

    private static void runWorkloads(int warmupMs, int reps) {
        Workloads workloads = new Workloads();
        for (int index = 0; index < workloads.count(); index++) {
            String name = workloads.name(index);
            int ops = workloads.ops(index);
            int batch = workloads.batch(index);
            try {
                Workloads.Workload workload = workloads.workload(index);
                long warmupStart = System.nanoTime();
                long deadline = warmupStart + warmupMs * 1_000_000L;
                Object checksum = null;
                while (System.nanoTime() < deadline) checksum = workload.run();
                long warmupElapsed = (System.nanoTime() - warmupStart) / 1_000_000L;

                double[] seconds = new double[reps];
                for (int rep = 0; rep < reps; rep++) {
                    long start = System.nanoTime();
                    for (int i = 0; i < batch; i++) checksum = workload.run();
                    seconds[rep] = (System.nanoTime() - start) / 1e9 / ((double) batch * ops);
                }
                Arrays.sort(seconds);
                System.out.printf(Locale.ROOT,
                    "BENCH %s %.3f %.3f %.3f batch=%d ops=%d warmupMs=%d checksum=%s%n",
                    name, seconds[reps / 2] * 1e9, seconds[0] * 1e9, seconds[reps - 1] * 1e9,
                    batch, ops, warmupElapsed, String.valueOf(checksum));
            } catch (Throwable failure) {
                System.out.printf(Locale.ROOT, "BENCH %s FAILED %s%n", name, failure);
            }
            System.out.flush();
        }
    }
}
