fn greet(who: str): str = "hello {who}"

fn main(args: [str]) {
    for a in args.skip(1) {
        print(greet(a))
    }
}
