package bench;

import java.util.Arrays;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Workload set for comparing JVM implementations. Every workload is deterministic
 * and returns a checksum, so two runtimes can be checked for identical results
 * while their timings are compared.
 *
 * Only java.base is used: the same jar must run on the OpenJ9 port and on a
 * HotSpot Zero build whose class library may be a different JDK major.
 */
public final class Workloads {
    public interface Workload {
        Object run();
    }

    /** One workload: name, operations per invocation, and the body. */
    public record Entry(String name, int ops, Workload workload) {}

    private static final class Node {
        final int value;
        final Node next;
        Node(int value, Node next) { this.value = value; this.next = next; }
    }

    private long seed = 0x123456789abcdefL;
    private final int[] numbers = new int[8192];
    private final double[] fractions = new double[1024];
    private final long[] longs = new long[2048];
    private final byte[] bytes = new byte[16384];
    private final String[] words = new String[512];
    private final Integer[] keys = new Integer[256];
    private final Interpreter[] operations = {
        x -> x + 17, x -> x ^ 0x13579bdf, x -> x * 33, x -> (x << 5) | (x >>> 27)
    };
    private Node retained;

    private interface Interpreter { int apply(int x); }

    public Workloads() {
        for (int i = 0; i < numbers.length; i++) numbers[i] = (i * 0x9e3779b9) ^ (i >>> 3);
        for (int i = 0; i < fractions.length; i++) fractions[i] = (i + 1) / 1024.0;
        for (int i = 0; i < longs.length; i++) longs[i] = i * 0x2545F4914F6CDD1DL;
        for (int i = 0; i < bytes.length; i++) bytes[i] = (byte) (i * 31);
        for (int i = 0; i < words.length; i++) words[i] = "w" + i;
        for (int i = 0; i < keys.length; i++) keys[i] = 10000 + i;
    }

    // --- scalar ---------------------------------------------------------------

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

    private int intArithmetic() {
        int a = 1, b = 7, c = 0;
        for (int i = 0; i < 10000; i++) {
            a = a * 31 + i;
            b ^= a >>> 3;
            c += (a & 0xff) - (b & 0x7f);
        }
        return a ^ b ^ c;
    }

    private double floatingPoint() {
        double a = 0.25, b = 0.0;
        for (int i = 0; i < 10000; i++) {
            a = (a + fractions[i & 1023]) * 0.99991;
            b += a * 0.0001;
        }
        return b;
    }

    private float floatMath() {
        float a = 1.5f;
        for (int i = 0; i < 10000; i++) a = a * 1.000001f + (i & 7);
        return a;
    }

    private long longDivision() {
        long acc = 0;
        for (int i = 1; i <= 4000; i++) acc += (seed / i) ^ (seed % i);
        return acc;
    }

    private int branchy() {
        int hits = 0;
        for (int i = 0; i < 20000; i++) {
            if ((i & 1) == 0) hits++;
            else if ((i % 3) == 0) hits += 2;
            else if ((i % 5) == 0) hits += 3;
            else hits--;
        }
        return hits;
    }

    private int switchTable() {
        int acc = 0;
        for (int i = 0; i < 20000; i++) {
            acc += switch (i & 7) {
                case 0 -> 1;
                case 1 -> 2;
                case 2 -> 3;
                case 3 -> 5;
                case 4 -> 8;
                case 5 -> 13;
                case 6 -> 21;
                default -> 34;
            };
        }
        return acc;
    }

    private long recursion() {
        return fib(18) + ackermann(2, 3);
    }

    private static int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

    private static int ackermann(int m, int n) {
        if (m == 0) return n + 1;
        if (n == 0) return ackermann(m - 1, 1);
        return ackermann(m - 1, ackermann(m, n - 1));
    }

    // --- arrays ---------------------------------------------------------------

    private long arrayScan() {
        long sum = 0;
        for (int value : numbers) sum += value ^ (value >>> 13);
        return sum;
    }

    private long longArrayScan() {
        long sum = 0;
        for (long value : longs) sum ^= value + (value >>> 9);
        return sum;
    }

    private int byteArraySum() {
        int sum = 0;
        for (byte value : bytes) sum += value;
        return sum;
    }

    private int arraySort() {
        int[] copy = numbers.clone();
        Arrays.sort(copy);
        return copy[0] ^ copy[copy.length - 1];
    }

    private int arrayFill() {
        int[] scratch = new int[4096];
        Arrays.fill(scratch, 0x5a5a5a5a);
        return scratch[0] ^ scratch[4095];
    }

    private long twoDimensional() {
        int[][] grid = new int[64][64];
        for (int r = 0; r < 64; r++)
            for (int c = 0; c < 64; c++) grid[r][c] = r * c;
        long sum = 0;
        for (int r = 0; r < 64; r++)
            for (int c = 0; c < 64; c++) sum += grid[r][c];
        return sum;
    }

    // --- objects, calls, collections ------------------------------------------

    private int virtualDispatch() {
        int value = 12345;
        for (int i = 0; i < 10000; i++) value = operations[i & 3].apply(value);
        return value;
    }

    private Object allocation() {
        Node head = null;
        for (int i = 0; i < 1024; i++) head = new Node(i, head);
        retained = head;
        // A stable value, not the node's identity hash, so runtimes compare.
        long sum = 0;
        for (Node node = head; node != null; node = node.next) sum += node.value;
        return sum;
    }

    private long objectArray() {
        Node[] nodes = new Node[512];
        for (int i = 0; i < nodes.length; i++) nodes[i] = new Node(i, null);
        long sum = 0;
        for (Node node : nodes) sum += node.value;
        return sum;
    }

    private long hashMap() {
        Map<Integer, Integer> map = new HashMap<>(512);
        for (Integer key : keys) map.put(key, key);
        long sum = 0;
        for (Integer key : keys) sum += map.get(key).intValue();
        return sum;
    }

    private long linkedHashMap() {
        Map<String, Integer> map = new LinkedHashMap<>(256);
        for (int i = 0; i < 256; i++) map.put(words[i], i);
        long sum = 0;
        for (Map.Entry<String, Integer> entry : map.entrySet()) sum += entry.getValue();
        return sum;
    }

    private int stringConcat() {
        int length = 0;
        for (int i = 0; i < 2000; i++) {
            String text = "w" + (i & 511) + '-' + i;
            length += text.length();
        }
        return length;
    }

    private int stringCompare() {
        int hits = 0;
        for (int i = 0; i < 2000; i++) {
            if (words[i & 511].equals("w" + (i & 511))) hits++;
            if (words[i & 511].compareTo("w511") < 0) hits++;
        }
        return hits;
    }

    private long exceptionThrow() {
        long depth = 0;
        for (int i = 0; i < 500; i++) {
            try {
                if ((i & 1) == 0) throw new IllegalStateException("probe");
            } catch (IllegalStateException expected) {
                depth += expected.getStackTrace().length;
            }
        }
        return depth;
    }

    private int interfaceCalls() {
        Interpreter local = x -> x + 1;
        int value = 0;
        for (int i = 0; i < 10000; i++) value = local.apply(value);
        return value;
    }

    private long streams() {
        long total = 0;
        for (int i = 0; i < 20; i++) {
            total += java.util.stream.IntStream.range(0, 2000).map(x -> x * 3).filter(x -> (x & 1) == 0).sum();
        }
        return total;
    }

    private long synchronization() throws InterruptedException {
        Object lock = new Object();
        long[] counter = {0};
        Thread thread = new Thread(() -> {
            for (int i = 0; i < 20000; i++) {
                synchronized (lock) { counter[0]++; }
            }
        });
        thread.start();
        for (int i = 0; i < 20000; i++) {
            synchronized (lock) { counter[0]++; }
        }
        thread.join();
        return counter[0];
    }

    private static final String[] NAMES = {
        "integerMix", "intArithmetic", "floatingPoint", "floatMath", "longDivision",
        "branchy", "switchTable", "recursion", "arrayScan", "longArrayScan",
        "byteArraySum", "arraySort", "arrayFill", "twoDimensional", "virtualDispatch",
        "allocation", "objectArray", "hashMap", "linkedHashMap", "stringConcat",
        "stringCompare", "exceptionThrow", "interfaceCalls", "streams", "synchronization"
    };

    /** Invocations per timed repetition; fixed so every runtime does identical work. */
    private static final int[] BATCH = {
        200, 200, 200, 200, 200,
        200, 200, 2, 200, 200,
        200, 50, 200, 100, 200,
        400, 200, 200, 200, 200,
        200, 6, 200, 8, 4
    };

    private static final int[] OPS = {
        10000, 10000, 10000, 10000, 4000,
        20000, 20000, 1, 8192, 2048,
        16384, 8192, 4096, 4096, 10000,
        1024, 512, 512, 256, 2000,
        2000, 500, 10000, 1, 40000
    };

    public int count() { return NAMES.length; }

    public String name(int index) { return NAMES[index]; }

    public int ops(int index) { return OPS[index]; }

    public int batch(int index) { return BATCH[index]; }

    public Workload workload(int index) throws ReflectiveOperationException {
        String suffix = switch (index) {
            case 0 -> "integerMix";
            case 1 -> "intArithmetic";
            case 2 -> "floatingPoint";
            case 3 -> "floatMath";
            case 4 -> "longDivision";
            case 5 -> "branchy";
            case 6 -> "switchTable";
            case 7 -> "recursion";
            case 8 -> "arrayScan";
            case 9 -> "longArrayScan";
            case 10 -> "byteArraySum";
            case 11 -> "arraySort";
            case 12 -> "arrayFill";
            case 13 -> "twoDimensional";
            case 14 -> "virtualDispatch";
            case 15 -> "allocation";
            case 16 -> "objectArray";
            case 17 -> "hashMap";
            case 18 -> "linkedHashMap";
            case 19 -> "stringConcat";
            case 20 -> "stringCompare";
            case 21 -> "exceptionThrow";
            case 22 -> "interfaceCalls";
            case 23 -> "streams";
            case 24 -> "synchronization";
            default -> throw new IllegalArgumentException("no workload " + index);
        };
        var method = Workloads.class.getDeclaredMethod(suffix);
        method.setAccessible(true);
        return () -> {
            try {
                return method.invoke(this);
            } catch (ReflectiveOperationException failure) {
                throw new IllegalStateException(failure);
            }
        };
    }
}
