/*ЗАДАНИЕ №1*/
---ПРИЧИНА:
--Запрос на вставку (INSERT) сканирует все строки таблицы orders, 
--а также имеется большое количество не нужных индексов, 
--что в свою очередь приводит к потере производительности
---ПЛАН РЕШЕНИЯ:
--1. Проанализировать запрос
explain analyse
INSERT INTO orders
    (order_id, order_dt, user_id, device_type, city_id, total_cost, discount, 
    final_cost)
SELECT MAX(order_id) + 1, current_timestamp, 
    '329551a1-215d-43e6-baee-322f2467272d', 
    'Mobile', 1, 1000.00, null, 1000.00
FROM orders;

--2. Оптимизировать индексы для таблицы orders:
--   -удалить лишние индексы и оставить только наиболее востребованные, т.к. частый поиск производится по полям order_id, user_id
--   -вставка новых значений в таблицу регулярно перестраивает индексы.
--   -часть индексов не релевантно (повторы и null)
--   -index на timestamp - избыточный
DROP index if exists
    orders_city_id_idx,
    orders_device_type_city_id_idx,
    orders_device_type_idx,
    orders_discount_idx,
    orders_final_cost_idx,
    orders_final_cost_idx,
    orders_order_dt_idx,
    orders_total_cost_idx,
    orders_total_final_cost_discount_idx;

--3. Создать sequence, который вызывает сканирование всей таблицы для поиска max значения 
--на поле order_id, с целью оптимизации   
CREATE sequence if not exists seq_ord_id increment by 1
	owned by public.orders.order_id;

SELECT setval('seq_ord_id', (select max(order_id) from orders));

ALTER TABLE public.orders
ALTER COLUMN order_id SET default nextval('seq_ord_id');

--4. Добавить default значения на поле order_dt
alter table public.orders
alter column order_dt set default current_timestamp;

--5. Скорректировать запрос на вставку так, чтобы все строки таблицы orders сканировались не последовательно и посмотреть план запроса
--Для этого целесообразно удалить select и значения, который будут вставляться автоматически (order_id, order_dt)
explain analyse verbose
INSERT INTO orders
    (user_id, device_type, city_id, total_cost, discount, final_cost)
values
    ('329551a1-215d-43e6-baee-322f2467272d', 'Mobile', 1, 1000.00, null, 1000.00);

/*ЗАДАНИЕ №2*/
---ПРИЧИНА:
--Использование не корректных типов данных в таблице users, 
--а также последовательное сканирование (Seq Scan) данной таблицы
---ПЛАН РЕШЕНИЯ:
--1. Проанализировать запрос 
explain analyse
SELECT user_id::text::uuid, first_name::text, last_name::text, 
    city_id::bigint, gender::text
FROM users
WHERE city_id::integer = 4
    AND date_part('day', to_date(birth_date::text, 'yyyy-mm-dd')) 
        = date_part('day', to_date('31-12-2023', 'dd-mm-yyyy'))
    AND date_part('month', to_date(birth_date::text, 'yyyy-mm-dd')) 
        = date_part('month', to_date('31-12-2023', 'dd-mm-yyyy'));
		
--2. Оптимизировать типы данных
ALTER TABLE users ALTER COLUMN user_id type uuid using user_id::text::uuid;
alter table users alter column  first_name type text;
alter table users alter column  last_name type text;
alter table users alter column  city_id type int;
alter table users alter column  gender type text;
alter table users alter column birth_date type timestamp using to_timestamp(birth_date, 'YYYY-MM-DD HH24:MI:SS');
alter table users alter column registration_date type timestamp without time zone using to_timestamp(registration_date, 'YYYY-MM-DD HH24:MI:SS');

--3. Создать индекс users_city_id_idx для более быстрого поиска по городам
create index users_city_id_idx on users (city_id);

--4. Скорректировать запрос с учетом оптимизации и посмотреть план запроса
explain analyse
SELECT
    user_id, first_name, last_name, city_id, gender
FROM users
WHERE city_id::integer = 4
  AND date_part('day', birth_date::date)
    = date_part('day', to_date('31-12-2023', 'dd-mm-yyyy'))
  AND date_part('month', birth_date::date)
    = date_part('month', to_date('31-12-2023', 'dd-mm-yyyy'));

/*ЗАДАНИЕ №3*/
---ПРИЧИНА:
--Вероятно в процедуре add_payment не совсем эффективно выполняется вставка в таблицу sales.
--При анализе обнаружилось, что время на планирование запроса больше его выполнения
---ПЛАН РЕШЕНИЯ:
--1. Создать покрывающий индекс (INCLUDE), 
--так чтобы сканирование шло по индексу в таблице orders, тем самым производительность увеличиться
create index orders_order_id_user_id ON orders(order_id) include (order_id);

--2. Удалить вставку в таблицу payments из процедуры add_payment и посмотреть план запроса, 
--т.к. таблица payments полностью дублирует таблицу orders (order_id и final_cost)
--удалив её и проверив не нарушаются ли связи, можно увеличить производительность

create or replace procedure add_payment(IN p_order_id bigint, IN p_sum_payment numeric)
    language plpgsql
as
$$BEGIN
    INSERT INTO order_statuses (order_id, status_id, status_dt)
    VALUES (p_order_id, 2, statement_timestamp());

    INSERT INTO sales(sale_id, sale_dt, user_id, sale_sum)
    SELECT NEXTVAL('sales_sale_id_sq'), statement_timestamp(), user_id, p_sum_payment
    FROM orders WHERE order_id = p_order_id;
END;$$;

--3. Удалить таблицу payments
drop table if exists payments;

/*ЗАДАНИЕ №4*/
---ПРИЧИНА:
--Большая таблица логов, обращение с таблицей занимает большое кол-во времени
---ПЛАН РЕШЕНИЯ (предполагаемый):
--Попробовать осуществить партицирование исходя из дат логирования через наследование таблицы user_logs для этого:
--1. Удалить и пересоздать ограничение user_logs_pkey на поля (log_id, log_date) 
--2. Написать функцию на языке plpgsql, которая создаст квартальные партиции с использованием переменных
--3. Написать триггер к функции, который будет срабатывать до вставки в таблицу user_logs для каждого столбца (for each row)
--4. Протестировать функцию и триггер, вставить в таблицу user_logs тестовые значения
--5. Посмотреть план запросов и убедиться удалось ли добиться поиска по квартальной партиции и увеличению производительности

/*ЗАДАНИЕ 5*/
---ПЛАН РЕШЕНИЯ:
--1. C точки зрения производительности для оптимального сбора и хранения данных для такого отчёта, 
--можно созать материализованное предтавление, которое можно будет обновлять утром СЛЕДУЮЩЕГО дня, 
--поскольку в отчет не включается ТЕКУЩИЙ день
create materialized view statistics_dishes as
WITH stat_dish as ( --формирует CTE
SELECT
	o.order_dt::date as date,
    oi.count as dish_count,
    d.fish * oi.count as fish,
    d.spicy * oi.count as spicy,
    d.meat * oi.count as meat,
    extract(year from o.order_dt::date) - extract(year from u.birth_date::date) as raw_age,
    	CASE --добавляем условия исходя из возрастных групп
        WHEN extract(year from o.order_dt::date) - extract(year from u.birth_date::date) > 0
        	and extract(year from o.order_dt::date) - extract(year from u.birth_date::date) <= 20 
		THEN '0 - 20'
        WHEN extract(year from o.order_dt::date) - extract(year from u.birth_date::date) > 20
        	and extract(year from o.order_dt::date) - extract(year from u.birth_date::date) <= 30 
		THEN '20 - 30'
        WHEN extract(year from o.order_dt::date) - extract(year from u.birth_date::date) > 30
            and extract(year from o.order_dt::date) - extract(year from u.birth_date::date) <= 40 
		THEN '30 - 40'
        WHEN extract(year from o.order_dt::date) - extract(year from u.birth_date::date) > 40
            and extract(year from o.order_dt::date) - extract(year from u.birth_date::date) <= 100 
		THEN '40 - 100'
        END as age
FROM order_items oi
LEFT JOIN dishes d on oi.item = d.object_id --Делаем связку с таблицей
LEFT JOIN orders o on oi.order_id = o.order_id --Делаем связку с таблицей
LEFT JOIN users u on o.user_id = u.user_id --Делаем связку с таблицей
)
SELECT --Обращаемся к CTE, округляя и суммируя поля
    date,
    round(sum(fish)::numeric/sum(dish_count)*100) as fish,
    round(sum(spicy)::numeric/sum(dish_count)*100) as spicy,
    round(sum(meat)::numeric/sum(dish_count)*100) as meat,
    age
FROM stat_dish
GROUP BY date, age
ORDER BY date desc, age;