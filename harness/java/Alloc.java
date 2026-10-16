import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public class Alloc {
    public static void main(String[] args) throws Exception {
        int mib = args.length > 0 ? Integer.parseInt(args[0]) : 4096;
        List<byte[]> keep = new ArrayList<>();
        for (int i = 0; i < mib; i += 16) {
            byte[] b = new byte[16 * 1024 * 1024];
            Arrays.fill(b, (byte) 1);
            keep.add(b);
            if (i % 512 == 0) {
                System.out.println("allocated " + (i / 1024) + " GiB; heap total="
                        + Runtime.getRuntime().totalMemory() / (1024 * 1024) + "M max="
                        + Runtime.getRuntime().maxMemory() / (1024 * 1024) + "M");
            }
        }
        System.out.println("allocated all " + mib + " MiB OK");
    }
}
