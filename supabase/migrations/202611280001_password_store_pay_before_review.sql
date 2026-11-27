-- Password Store: collect product payment before admin review.
-- Delivery is excluded from the amount paid by transfer and is collected on delivery.

CREATE OR REPLACE FUNCTION public.create_store_order(
  p_customer_name text,
  p_phone text,
  p_delivery_type text,
  p_village text,
  p_address text,
  p_customer_notes text,
  p_payment_method text,
  p_items jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid;
  v_confirmed_at timestamptz;
  v_order_id uuid;
  v_item jsonb;
  v_product_id bigint;
  v_quantity integer;
  v_product_name text;
  v_price numeric(12,2);
  v_subtotal numeric(12,2) := 0;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'يجب تسجيل الدخول أولاً';
  END IF;

  SELECT email_confirmed_at INTO v_confirmed_at
  FROM auth.users WHERE id = v_user_id;
  IF v_confirmed_at IS NULL THEN
    RAISE EXCEPTION 'يجب تأكيد البريد الإلكتروني أولاً';
  END IF;

  IF array_length(regexp_split_to_array(trim(p_customer_name), '\s+'), 1) < 3 THEN
    RAISE EXCEPTION 'يجب إدخال الاسم الثلاثي';
  END IF;
  IF trim(p_phone) = '' THEN
    RAISE EXCEPTION 'رقم الهاتف مطلوب';
  END IF;
  IF p_delivery_type NOT IN ('pickup', 'delivery') THEN
    RAISE EXCEPTION 'طريقة الاستلام غير صحيحة';
  END IF;
  IF p_delivery_type = 'delivery' AND (p_address IS NULL OR trim(p_address) = '') THEN
    RAISE EXCEPTION 'عنوان التوصيل مطلوب';
  END IF;
  IF p_payment_method IS NULL OR trim(p_payment_method) = '' THEN
    RAISE EXCEPTION 'طريقة الدفع مطلوبة';
  END IF;
  IF p_payment_method <> 'cash' AND NOT EXISTS (
    SELECT 1 FROM public.store_payment_methods
    WHERE code = p_payment_method AND enabled = true
  ) THEN
    RAISE EXCEPTION 'طريقة الدفع غير متاحة حالياً';
  END IF;
  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'السلة فارغة';
  END IF;

  INSERT INTO public.store_orders (
    user_id, customer_name, phone, delivery_type, city, village, address,
    customer_notes, payment_method, status, subtotal, delivery_fee, total
  )
  VALUES (
    v_user_id, trim(p_customer_name), trim(p_phone), p_delivery_type, 'قطور',
    NULLIF(trim(COALESCE(p_village, '')), ''),
    NULLIF(trim(COALESCE(p_address, '')), ''),
    p_customer_notes, p_payment_method, 'pending_review', 0,
    CASE WHEN p_delivery_type = 'pickup' THEN 0 ELSE NULL END, 0
  )
  RETURNING id INTO v_order_id;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := (v_item->>'product_id')::bigint;
    v_quantity := (v_item->>'quantity')::integer;
    IF v_quantity IS NULL OR v_quantity < 1 OR v_quantity > 100 THEN
      RAISE EXCEPTION 'الكمية غير صحيحة';
    END IF;

    SELECT name, price INTO v_product_name, v_price
    FROM public.products
    WHERE id = v_product_id AND available = true AND is_demo = false;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'أحد المنتجات غير متاح حالياً';
    END IF;

    INSERT INTO public.store_order_items (
      order_id, product_id, product_name, unit_price, quantity, line_total
    )
    VALUES (
      v_order_id, v_product_id, v_product_name, v_price, v_quantity,
      v_price * v_quantity
    );
    v_subtotal := v_subtotal + (v_price * v_quantity);
  END LOOP;

  -- total is the product amount only; delivery is collected separately on receipt.
  UPDATE public.store_orders
  SET subtotal = v_subtotal, total = v_subtotal
  WHERE id = v_order_id;

  RETURN v_order_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.customer_submit_payment_receipt(
  p_order_id uuid,
  p_receipt_path text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'storage'
AS $function$
DECLARE
  v_order public.store_orders%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'يجب تسجيل الدخول أولاً';
  END IF;

  SELECT * INTO v_order
  FROM public.store_orders
  WHERE id = p_order_id AND user_id = auth.uid()
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'الطلب غير موجود';
  END IF;

  IF v_order.status NOT IN ('pending_review', 'confirmed')
     OR v_order.payment_method = 'cash'
     OR v_order.payment_status IN ('paid', 'under_review') THEN
    RAISE EXCEPTION 'الطلب غير متاح لاستقبال إيصال';
  END IF;

  IF p_receipt_path IS NULL
     OR (storage.foldername(p_receipt_path))[1] <> auth.uid()::text
     OR (storage.foldername(p_receipt_path))[2] <> p_order_id::text
     OR split_part(p_receipt_path, '/', 4) <> ''
     OR split_part(p_receipt_path, '/', 3) = '' THEN
    RAISE EXCEPTION 'مسار الإيصال غير صحيح';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM storage.objects
    WHERE bucket_id = 'payment-receipts' AND name = p_receipt_path
  ) THEN
    RAISE EXCEPTION 'ملف الإيصال لم يتم رفعه';
  END IF;

  UPDATE public.store_orders
  SET receipt_path = p_receipt_path,
      payment_status = 'under_review'
  WHERE id = p_order_id;

  RETURN true;
END;
$function$;
