import java.util.HashMap;

/**
 * Interpreter benchmark for the embedded iOS runtime.
 *
 * Deliberately JDK-only (java.base) so it runs unchanged in the Simulator app, on a
 * desktop JVM, and in the core-only runtime variant. Each workload is the same code as
 * work/performance/openj9-zero/InterpreterBench.java, minus JMH, because the iOS app
 * cannot host the JMH harness.
 */
public final class Bench {
    private static final class Node {
        final int value;
        final Node next;
        Node(int value, Node next) { this.value = value; this.next = next; }
    }
    private interface Op { int apply(int x); }
    private static final class Add implements Op { public int apply(int x) { return x + 17; } }
    private static final class Xor implements Op { public int apply(int x) { return x ^ 0x13579bdf; } }
    private static final class Multiply implements Op { public int apply(int x) { return x * 33; } }
    private static final class Rotate implements Op { public int apply(int x) { return (x << 5) | (x >>> 27); } }
    private interface Workload { Object run(); }

    private long seed = 0x123456789abcdefL;
    private final int[] numbers = new int[8192];
    private final double[] fractions = new double[1024];
    private final Op[] operations = {new Add(), new Xor(), new Multiply(), new Rotate()};
    private final Integer[] keys = new Integer[256];
    private Node retained;

    private Bench() {
        for (int i = 0; i < numbers.length; i++) numbers[i] = (i * 0x9e3779b9) ^ (i >>> 3);
        for (int i = 0; i < fractions.length; i++) fractions[i] = (i + 1) / 1024.0;
        for (int i = 0; i < keys.length; i++) keys[i] = Integer.valueOf(10000 + i);
    }

    private long integerMix() {
        long x = seed;
        for (int i = 0; i < 10000; i++) {
            x ^= x >>> 12;
            x ^= x << 25;
            x ^= x >>> 27;
            x *= 2685821657736338717L;
        }
        seed = x;
        return x;
    }

    private double floatingPoint() {
        double a = 0.25, b = 0.0;
        for (int i = 0; i < 10000; i++) {
            a = (a + fractions[i & 1023]) * 0.99991;
            b += a * 0.0001;
        }
        return b;
    }

    private long arrayScan() {
        long sum = 0;
        for (int value : numbers) sum += value ^ (value >>> 13);
        return sum;
    }

    private int virtualDispatch() {
        int value = 12345;
        for (int i = 0; i < 10000; i++) value = operations[i & 3].apply(value);
        return value;
    }

    private Node allocation() {
        Node head = null;
        for (int i = 0; i < 1024; i++) head = new Node(i, head);
        retained = head;
        return head;
    }

    private long hashMap() {
        HashMap<Integer, Integer> map = new HashMap<>(512);
        for (Integer key : keys) map.put(key, key);
        long sum = 0;
        for (Integer key : keys) sum += map.get(key).intValue();
        return sum;
    }

    private static final String[] NAMES = {
        "integerMix", "floatingPoint", "arrayScan", "virtualDispatch", "allocation", "hashMap"
    };
    private static final int[] OPS = {10000, 10000, 8192, 10000, 1024, 512};
    // Invocations per timed repetition. Fixed so every runtime performs identical work;
    // a probe-derived batch would change allocation volume and therefore GC behaviour.
    private static final int[] BATCH = {200, 200, 200, 200, 400, 200};

    private static Workload workload(Bench bench, int index) {
        return switch (index) {
            case 0 -> bench::integerMix;
            case 1 -> bench::floatingPoint;
            case 2 -> bench::arrayScan;
            case 3 -> bench::virtualDispatch;
            case 4 -> bench::allocation;
            case 5 -> bench::hashMap;
            default -> throw new IllegalArgumentException();
        };
    }

    public static void main(String[] args) {
        int warmupMs = Integer.getInteger("bench.warmupMs", 300);
        int reps = Integer.getInteger("bench.reps", 7);
        System.out.println("BENCH_HOST vm=" + System.getProperty("java.vm.name")
            + " version=" + System.getProperty("java.runtime.version")
            + " os=" + System.getProperty("os.name")
            + " arch=" + System.getProperty("os.arch")
            + " cpus=" + Runtime.getRuntime().availableProcessors()
            + " heap=" + Runtime.getRuntime().maxMemory()
            + " warmupMs=" + warmupMs + " reps=" + reps);
        for (int index = 0; index < NAMES.length; index++) {
            Bench bench = new Bench();
            Workload work = workload(bench, index);
            long deadline = System.nanoTime() + warmupMs * 1_000_000L;
            while (System.nanoTime() < deadline) work.run();
            int batch = BATCH[index];
            double[] seconds = new double[reps];
            for (int rep = 0; rep < reps; rep++) {
                long start = System.nanoTime();
                for (int i = 0; i < batch; i++) work.run();
                seconds[rep] = (System.nanoTime() - start) / 1e9 / ((double) batch * OPS[index]);
            }
            java.util.Arrays.sort(seconds);
            double median = seconds[reps / 2];
            double min = seconds[0];
            double max = seconds[reps - 1];
            System.out.printf(java.util.Locale.ROOT, "BENCH %s %.3f %.3f %.3f batch=%d%n",
                NAMES[index], median * 1e9, min * 1e9, max * 1e9, batch);
        }
        System.out.println("OPENJ9_IOS_BENCH_OK");
        System.out.flush();
    }
}
