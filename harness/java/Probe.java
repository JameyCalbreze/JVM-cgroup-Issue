public class Probe {
    public static void main(String[] args) {
        Runtime r = Runtime.getRuntime();
        System.out.println("maxMemory=" + r.maxMemory()
                + " totalMemory=" + r.totalMemory()
                + " maxMemoryGiB=" + String.format("%.2f", r.maxMemory() / 1073741824.0)
                + " totalMemoryGiB=" + String.format("%.2f", r.totalMemory() / 1073741824.0));
    }
}
